# Write your own backend

Time&I tracks your time locally and pushes it to whatever holds your task
list and timesheet. OpenProject is supported today and standalone (no
backend) works now; everything else — Toggl, Jira, GitHub Issues, a bespoke
internal tracker — plugs in behind one protocol, `TaskBackend`. This guide is
the complete walk-through for writing one. It assumes you have read
[CONTRIBUTING.md](../CONTRIBUTING.md) and can build the checks
(`swift run timeandeyeChecks`).

The public-API spec at
[`docs/superpowers/specs/2026-07-12-public-api-surface.md`](superpowers/specs/2026-07-12-public-api-surface.md)
defines the sealed surface a backend links against; this document is the
how-to that sits on top of it.

## What a backend IS

A backend is a translator. On one side is the **local journal** — a SQLite
file on the Mac that is the single source of truth for what you spent time
on. On the other is a remote service that holds tasks and accepts time
entries. Your conformer reads the remote task list so time can be attributed,
and posts confirmed time back so the remote record matches the journal.

The invariant that shapes everything else: **the journal stays the source of
truth; the backend never becomes one.** Your conformer reflects the journal
outward. It does not pull remote time entries back in as new local truth, it
does not invent tasks the user never looked at, and it does not decide on its
own what the user was working on. A backend that went offline for a week and
came back must be able to catch the remote service up from the journal, never
the reverse. Standalone mode is simply the absence of any backend: with no
conformer registered there is no sync engine at all, so nothing can be marked
"pushed" without a real destination.

## The protocol, method by method

`TaskBackend` (in `timeandeyeCore/TaskBackend.swift`) is a class-bound
protocol — one long-lived conformer instance per connected service. It splits
into identity, task-list reads, time-entry writes, comments, and an
invoice-lock hook. The reference implementation is `OPBackend` in the same
module; read it alongside this list.

### Identity and capabilities

```swift
var displayName: String { get }          // "OpenProject", "Toggl" — shown in Settings and errors
var pageRecognizer: BackendPageRecognizer { get }   // the page-recognition hook, below
var supportsActivities: Bool { get }     // false hides the activity-type pickers in Settings
var supportsTaskComments: Bool { get }   // false = the app skips comment-to-task instead of erroring
func owns(_ ref: TaskRef) -> Bool        // is this task one of yours?
```

`owns(_:)` is how the sync fan-out routes: a task tracked against your service
must return `true`, one belonging to a different backend must return `false`.
Sessions you do not own are skipped silently — they post when their own
backend reconnects — so never claim a ref you cannot service. `TaskRef` has
three cases: `.op(Int)` (OpenProject), `.remote(String)` (the case a new
GUID-keyed backend uses), and `.local(UUID)` (device-only tasks that never
push). A new backend owns `.remote` refs whose id it minted.

### Task-list reads

```swift
func fetchTasks() async throws -> [WorkTask]
func fetchMe() async throws -> String
func fetchActivities() async throws -> [TimeActivity]
func taskURL(id: String) -> URL?
func taskTimeEntriesURL(id: String) -> URL?   // has a default of nil
```

- `fetchTasks()` returns the user's open tasks as `WorkTask` values (ref,
  subject, project, project id, status). These populate the pick list and give
  the attributor its candidate pool.
- `fetchMe()` returns who the stored credentials authenticate as. It is
  surfaced in Settings so time can never be logged silently to the wrong
  account — treat an unexpected identity as a reason to stop, not a cosmetic
  string.
- `fetchActivities()` returns the service's per-entry activity types (OP:
  Development, Management, …). A service with no such concept returns `[]` and
  sets `supportsActivities` to `false`. (`TimeActivity` is currently a type
  alias for `OPTimeActivity`, a plain `id`/`name` pair.)
- `taskURL(id:)` builds the task's web page for "Open in <backend>".
  `taskTimeEntriesURL(id:)` points at where the user checks logged time; it
  defaults to `nil`, which falls back to `taskURL`.

Task ids cross the seam as `String` (the `TaskRef.backendTaskID` form). A
backend whose native ids are integers or GUIDs converts at its own edge, the
way `OPBackend` parses `Int(id)` and surfaces a clear error on anything
non-numeric rather than silently no-op'ing.

### Time-entry writes

```swift
func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                     activityID: Int?, comment: String?) async throws -> RemoteEntryID?
func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                     duration: TimeInterval, activityID: Int?,
                     comment: String?) async throws
func updateEntryComment(id: RemoteEntryID, comment: String) async throws
func deleteTimeEntry(id: RemoteEntryID) async throws
func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry]
```

- `createTimeEntry` posts one slice and returns the id the service assigned
  (or `nil` if it replied without one). `RemoteEntryID` is a `String`. Own
  your service's encoding quirks here — OP's "retry without a start time on a
  422" lives inside `OPBackend`, not in the shared engine.
- `updateTimeEntry` / `updateEntryComment` / `deleteTimeEntry` amend an entry
  the journal already knows the id of.
- `listTimeEntries(from:to:)` returns the current user's remote entries in a
  window as `RemoteTimeEntry` values — the input to duplicate reconciliation
  and to verifying an entry the engine is unsure it created. A service that
  cannot list returns `[]`. Set `hasStart` to `false` on a `RemoteTimeEntry`
  if the service does not record a real per-entry start (e.g. day-granular
  time), so grouping does not trust a fabricated minute.

### The page-recognition hook

`pageRecognizer` returns a `BackendPageRecognizer` — the attribution engine's
"the user is looking at task N right now" signal. When a task's web page is
frontmost in the browser, this is what turns the captured URL into a
`TaskRef` at near-certain confidence.

```swift
func taskRef(inURL urlString: String) -> TaskRef?   // task page URL -> ref
func taskRef(inTitle title: String) -> TaskRef?     // fallback: PWA window title
func isProjectPage(_ url: URL) -> Bool              // a project page with no single task
func projectHint(in url: URL) -> String?            // has a default of nil
```

If your service's pages carry no task identity, return the built-in
`NoPageRecognizer()` and you are done — everything still works, you just lose
the "open the task page to start its timer" convenience. `isProjectPage`
returning `true` tells the ranker to trust its priors harder ("the most likely
task in this project"); `projectHint` scopes that boost to a single project.

### The error contract — why the engine routes on your errors

This is the part most worth getting right. When a write fails, *how* you fail
decides what the engine does next:

- Throw **`PermanentPostError(reason:)`** when a post can never succeed — the
  task was deleted at the service, there is no mapping for it, the entry is
  frozen. The engine closes that row `.skipped` with your reason and **moves
  on**, so one dead session never dams the queue behind it.
- Throw **`AmendmentError`** from an update or delete that cannot proceed as
  asked. `.frozen(reason)` parks the row `.diverged` and surfaces it — the
  books and the journal genuinely disagree and only a human can reconcile
  them. `.mustRecreate` tells the engine to delete-and-recreate because the
  service cannot move the entry in place (e.g. across projects).
- Throw **anything else** (network errors, 5xx, rate limits) for a *transient*
  failure. The engine keeps the row retryable and tries again on the next
  pass.

The classification is yours to make because only your conformer can tell a
404-the-task-is-gone from a 503-try-later. Reach for a plain thrown error by
default; use `PermanentPostError` / `AmendmentError` deliberately, only when
you are sure retrying is pointless.

### The invoice-lock hook (optional)

```swift
func invoiceLocks(for ids: [RemoteEntryID]) async throws -> [RemoteEntryID: String]
```

Has a default of `[:]` (nothing ever locks). Implement it only for a service
with an invoicing concept: return the subset of `ids` covered by a sent
invoice, mapped to the invoice reference. The engine then refuses to amend
billed time. A project tracker with no invoicing leaves the default alone.

## The transport seam — how to stay testable

Never reach for `URLSession` directly. `TaskBackend` conformers take an
injected `HTTPTransport`:

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

The real app supplies a `URLSession`-backed implementation; the checks supply
a fake that returns canned responses, so every backend behaviour is testable
without a live server and without a network. Build your `URLRequest`, hand it
to the transport, and switch on the `HTTPURLResponse` status yourself — that
status check is exactly where you decide transient-vs-permanent (above). Write
your checks against a stub transport the same way `OPClient`'s do.

## Registering the backend

A conformer does nothing until it is registered. Registration happens from
inside an app build at startup — the community app here, a fork, or a
separately-licensed build — not from a standalone package dropped in at
runtime (there is no dynamic plugin loading; the registration seam is
in-package). So the usual path is: write your `TaskBackend` conformer (that
part only needs the public Core seam and can live in its own module), then
register it where the app wires up its backends. Registration names the
connection's **stable id** and its **class**:

- **`BackendClass.pm`** (project management) receives *all* confirmed time for
  the tasks it `owns()` — the complete record, billable or not.
- **`BackendClass.finance`** (invoicing) receives *only* effectively-billable
  time, and never sees non-billable projects or personal tasks.

`BackendClass` is an open raw-string struct, not an enum, precisely so a
separately-licensed build can add its own classes without editing this
package.

The stable id keys the posting ledger and must never change across launches
(a changed id re-posts history). Mint one at connect time and persist it with
the connection's settings.

A free/community backend registers through the host app's unguarded seam:

```swift
appController.register(backend: myBackend,
                       id: "my-tracker-<account>",   // stable, persisted
                       class: .pm)
```

A paid backend that must check a licence registers through the
**entitlement-gated** overload on `BackendRegistry`, declaring a
`BackendEntitlementRequirement`:

```swift
let requirement = BackendEntitlementRequirement(
    requiredTier: .plus,           // class floor: "any paid tier"
    connectorID: "my-tracker")     // matched against the key's signed allowlist
let decision = registry.register(myBackend, id: "my-tracker-<account>",
                                 class: .finance, requires: requirement)
// .allowed registers it; .denied(reason) registers NOTHING and hands back
// the reason for the Settings copy.
```

Both gates must pass — membership in the licence key's signed connector
allowlist *and* the tier floor — and a denial is fail-closed: the backend
never enters the registry, so the sync fan-out never sees it. That paid path
belongs to a separately-licensed build; a community backend uses the unguarded
form above.

## Invariants a backend must respect

- **Local-first, always.** The journal is the source of truth. Your conformer
  reflects it outward and never pulls remote entries back in as new local
  truth.
- **Never fabricate task identity.** A task exists in the pick list because
  `fetchTasks()` returned it or the user created it — never because your
  conformer guessed. The attribution learner trains on the sensor signal
  (window, app, URL) *only*; it must never train on text your API returned.
  Feed observed signals in, never invented ones.
- **Own only what you can service.** `owns()` must be exact. A ref you claim
  but cannot post is worse than one you disown.
- **Fail honestly.** Use the error contract to tell the engine the truth about
  a failure. A transient error dressed as permanent loses time; a permanent
  error dressed as transient dams the queue.

## A minimal worked example

Below is a complete, copyable conformer for a fictional REST time tracker.
Every required member is implemented; the bodies are deliberately small so the
*shape* is clear. It is illustrative code (kept in this doc, not compiled into
the package), correct against the protocol as of this writing — always
cross-check the live `TaskBackend.swift` and `OPBackend.swift` before you
ship. Substitute your service's real HTTP and JSON.

```swift
import Foundation
import timeandeyeCore

/// A backend for a fictional "Example Tracker" REST service. Tasks and time
/// entries are identified by GUID strings, so it owns `.remote` refs. The
/// journal stays the source of truth; this type only translates.
final class ExampleBackend: TaskBackend {

    private let baseURL: URL
    private let apiToken: String
    private let transport: HTTPTransport   // injected — never URLSession directly

    init(baseURL: URL, apiToken: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.transport = transport
    }

    // MARK: Identity & capabilities

    var displayName: String { "Example Tracker" }
    var supportsActivities: Bool { false }      // this service has no activity types
    var supportsTaskComments: Bool { false }    // no post-a-note-to-the-task endpoint

    /// Task pages carry no recognisable id in this example, so recognise
    /// nothing. A real backend returns a custom BackendPageRecognizer here.
    var pageRecognizer: BackendPageRecognizer { NoPageRecognizer() }

    /// Own the GUID-keyed `.remote` refs this backend minted; disown the rest.
    func owns(_ ref: TaskRef) -> Bool {
        if case .remote = ref { return true }
        return false
    }

    // MARK: Task list

    func fetchTasks() async throws -> [WorkTask] {
        let (data, response) = try await transport.send(get("tasks"))
        try check(response)                          // throws transient on non-2xx
        return try decodeTasks(data).map { row in
            WorkTask(ref: .remote(row.id), subject: row.title,
                     project: row.projectName, projectID: row.projectID,
                     status: row.status)
        }
    }

    func fetchMe() async throws -> String {
        let (data, response) = try await transport.send(get("me"))
        try check(response)
        return try decodeMe(data).displayName        // surfaced so time never
    }                                                // lands on the wrong account

    func fetchActivities() async throws -> [TimeActivity] { [] }   // none here

    func taskURL(id: String) -> URL? {
        baseURL.appendingPathComponent("tasks/\(id)")
    }
    // taskTimeEntriesURL uses the protocol default (nil -> falls back to taskURL)

    // MARK: Time entries

    func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                         activityID: Int?, comment: String?) async throws -> RemoteEntryID? {
        let body = try encodeEntry(taskID: taskID, start: start,
                                   duration: duration, comment: comment)
        let (data, response) = try await transport.send(post("entries", body))
        if response.statusCode == 404 {              // the task is gone — never retry
            throw PermanentPostError(reason: "Example task \(taskID) not found")
        }
        try check(response)                          // other non-2xx = transient
        return try decodeEntry(data).id              // the id the service assigned
    }

    func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                         duration: TimeInterval, activityID: Int?,
                         comment: String?) async throws {
        let body = try encodeEntry(taskID: taskID, start: start,
                                   duration: duration, comment: comment)
        let (_, response) = try await transport.send(put("entries/\(id)", body))
        if response.statusCode == 409 {              // locked by an invoice
            throw AmendmentError.frozen("entry \(id) is invoiced")
        }
        try check(response)
    }

    func updateEntryComment(id: RemoteEntryID, comment: String) async throws {
        let body = try encodeComment(comment)
        let (_, response) = try await transport.send(put("entries/\(id)", body))
        try check(response)
    }

    func deleteTimeEntry(id: RemoteEntryID) async throws {
        let (_, response) = try await transport.send(delete("entries/\(id)"))
        if response.statusCode == 404 { return }     // already gone = success
        try check(response)
    }

    func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry] {
        let (data, response) = try await transport.send(
            get("entries", query: dateWindow(from, to)))
        try check(response)
        return try decodeEntries(data).map { row in
            RemoteTimeEntry(id: row.id, taskID: row.taskID, start: row.start,
                            durationSeconds: row.seconds, comment: row.comment,
                            createdAt: row.createdAt, updatedAt: row.updatedAt,
                            hasStart: true)
        }
    }

    // MARK: Comments — no-op, since supportsTaskComments is false
    func addTaskComment(taskID: String, text: String) async throws {}

    // invoiceLocks uses the protocol default ([:] — nothing ever locks)

    // MARK: - Private helpers (build requests, decode JSON, classify status)
    // get/post/put/delete build a signed URLRequest against baseURL + apiToken;
    // decode* parse the service's JSON; `check` throws a transient error on any
    // non-2xx status the create/update paths did not already special-case.
    private func get(_ path: String, query: [URLQueryItem] = []) -> URLRequest { … }
    private func post(_ path: String, _ body: Data) -> URLRequest { … }
    private func put(_ path: String, _ body: Data) -> URLRequest { … }
    private func delete(_ path: String) -> URLRequest { … }
    private func check(_ response: HTTPURLResponse) throws { … }
    // ...encode*/decode*/dateWindow elided...
}
```

To wire it into a running app, mint and persist a stable id at connect time,
then register it (community form):

```swift
let backend = ExampleBackend(baseURL: url, apiToken: token,
                             transport: URLSessionTransport())
appController.register(backend: backend, id: "example-\(accountID)", class: .pm)
```

That is the whole contract. Keep the journal authoritative, classify your
failures honestly, inject the transport, and register with a stable id — the
rest of the app treats your service exactly as it treats OpenProject.

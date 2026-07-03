# TaskRef.remote(String) — migration plan

Written 2026-07-02. Goal: make GUID-keyed backends (Xero Projects) first-class by
adding a third `TaskRef` case, `remote(String)`, alongside `.op(Int)` and
`.local(UUID)`. `.op` stays as-is (OP work-package ints, all existing journal
rows keep decoding byte-identically); `.remote` carries the backend's task GUID
verbatim. `.local` semantics are untouched.

This plan is execution-ready: every code site is listed file:line against the
tree as of commit 6907245 (branch post-fable). Verify line drift with the greps
in §11 before editing.

## 0. Decisions (already made — do not re-litigate during execution)

- **One new case, not a String-only rewrite.** `.op(Int)` is NOT collapsed into
  `.remote(String)`: that would change the JSON wire shape of every journalled
  row, every pin, every email rule, every primed surface, and every
  `activityOverrides` key. Additive case = zero data migration.
- **`is_op` column keeps its NAME, its MEANING becomes "remote/pushable".**
  No `ALTER TABLE`, no backfill: every existing `is_op = 1` row is `.op`,
  which is still remote/pushable; every `0` row is `.local`, still not.
  `.remote` rows simply also write `1` from now on. Rename happens in
  comments/docs only.
- **The TaskBackend seam speaks String task ids**, mirroring the
  `RemoteEntryID` precedent (TaskBackend.swift:1-5, OPBackend.swift:48-56):
  the OP conformer converts at its edge and throws on a non-numeric id.
- **Backends declare ownership.** `TaskBackend` gains
  `func owns(_ ref: TaskRef) -> Bool` so a journal holding `.op` sessions can
  never push them to a connected Xero backend (and vice versa). Un-owned
  eligible sessions are *skipped silently* (they push when their backend is
  reconnected), never marked pushed, never an error.
- **`pushedToOP` / `opTimeEntryID` Swift names and JSON keys stay.** They were
  deliberately kept for wire stability when `opTimeEntryID` was widened to
  String (Models.swift:168-171). Doc-comment the meaning ("pushed to the
  connected backend"), do not rename.
- **GUID normalisation is the backend conformer's job.** Core stores whatever
  string the backend hands it and compares byte-for-byte. The (future, pro
  repo) XeroBackend must lowercase GUIDs at its edge so equality is stable.

## 1. Core model — Sources/andeyeTTCore/Models.swift

### 1a. The case (Models.swift:9-12)

```swift
/// Identity of a task. `.op` = OpenProject work package; `.remote` = a task in
/// a GUID-keyed backend (Xero), id stored verbatim (conformer normalises);
/// `.local` = andeye-only (leisure tracking etc.), never pushed.
public enum TaskRef: Hashable, Codable, Sendable {
    case op(Int)
    case remote(String)
    case local(UUID)
}
```

Synthesized Codable emits `{"remote":{"_0":"<guid>"}}`; existing rows
(`{"op":{"_0":7}}`, `{"local":{"_0":"..."}}`) decode unchanged because the case
set is additive. NO custom `init(from:)` needed. §9 freezes this with checks.

### 1b. New helpers (add below the enum, next to `isLocalOnly` at Models.swift:28-31)

```swift
public extension TaskRef {
    /// The id string a backend call needs: "\(n)" for .op, the GUID for
    /// .remote, nil for .local (local tasks never push).
    var backendTaskID: String? {
        switch self {
        case .op(let id): return String(id)
        case .remote(let id): return id
        case .local: return nil
        }
    }
    /// True for tasks that live in a remote backend — the push-eligibility
    /// test and the SQLite `is_op` column's real meaning.
    var isRemote: Bool { backendTaskID != nil }
    /// Label of last resort when the task cache has no subject for the ref.
    var fallbackLabel: String {
        switch self {
        case .op(let id): return "WP #\(id)"
        case .remote(let id): return "Task \(id.prefix(8))…"
        case .local: return "Local task"
        }
    }
}
```

`WorkTask.isLocalOnly` (Models.swift:28-31) is already correct for the new case
(`.remote` returns false) — no edit, but add the check in §9.

## 2. storageKey — Sources/andeyeTTCore/Settings.swift:31-36

Add the arm:

```swift
case .remote(let id): return "remote:\(id)"
```

Prefixes ("op:", "local:", "remote:") keep the key-space collision-free. Used
by `settings.taskColours` (Settings.swift:89-90; AppController.swift:1268,
1280, 1282, 1289). Existing saved maps are unaffected (String keys).
`activityOverrides: [TaskRef: Int]` (Settings.swift:58) encodes as a Codable
key/value array — additive case decodes fine; §9 check 13 proves it.

## 3. Journal semantics

### 3a. Protocol doc + in-memory store — Sources/andeyeTTCore/JournalStore.swift

- Line 22-24: reword the doc comment to
  `/// Sessions eligible for backend push: certainty >= threshold, not yet pushed, and on a remote (.op / .remote) task (local-only tasks never push).`
- Line 87 (`InMemoryJournalStore.sessions(needingPushAtOrAbove:)`): replace
  `guard case .op = session.task else { return false }` with
  `guard session.task.isRemote else { return false }`.

### 3b. SQLite store — Sources/andeyeTTMac/SQLiteJournalStore.swift

- Line 44: leave the DDL exactly as-is (`is_op INTEGER NOT NULL`). Add a
  comment above the CREATE TABLE:
  `-- is_op: 1 = remote/pushable task (.op OR .remote), 0 = .local. Column name is historic; renaming would force a table rewrite for zero behaviour gain.`
- Lines 166-167: replace
  `var isOP = 0; if case .op = session.task { isOP = 1 }` with
  `let isOP = session.task.isRemote ? 1 : 0`.
- Line 255: query text unchanged (`is_op = 1` now means "remote"); update the
  surrounding comment if any wording says OP.
- `latestEndByTask` (lines 286-291) decodes `TaskRef` from
  `json_extract(json, '$.task')` — works for `.remote` with no edit (verified:
  it round-trips through the same JSONDecoder). No backfill anywhere: no
  existing row can hold `.remote`.

## 4. Backend seam — Sources/andeyeTTCore/TaskBackend.swift

Widen task ids to String and add ownership. Full list of signature edits:

- Line ~35 (protocol body): add
  `/// Whether this ref belongs to this backend (an .op session must never push to Xero). func owns(_ ref: TaskRef) -> Bool`
- Line 51: `func taskURL(id: Int) -> URL?` → `func taskURL(id: String) -> URL?`
- Lines 57-58: `createTimeEntry(taskID: Int, ...)` → `taskID: String`
- Lines 59-61: `updateTimeEntry(id:taskID:...)` → `taskID: String`
- Line 71: `addTaskComment(taskID: Int, ...)` → `taskID: String`
- Lines 17-27 (`BackendPageRecognizer`): return refs, not ints:
  ```swift
  func taskRef(inURL urlString: String) -> TaskRef?
  func taskRef(inTitle title: String) -> TaskRef?
  func isProjectPage(_ url: URL) -> Bool          // unchanged
  ```
- Lines 76-81 (`NoPageRecognizer`): update the two method names/returns to
  `TaskRef?`, still `nil`.

## 5. OP conformer — Sources/andeyeTTCore/OPBackend.swift

- Add next to `opID` (lines 51-56), same throw-don't-no-op policy:
  ```swift
  /// OP task ids are ints; the seam speaks String. Non-numeric here can only
  /// mean cross-backend corruption — surface it.
  private func opTaskID(_ id: String) throws -> Int {
      guard let n = Int(id) else {
          throw OPClientError.malformedResponse("non-numeric OP task id '\(id)'")
      }
      return n
  }
  ```
- `owns`: `public func owns(_ ref: TaskRef) -> Bool { if case .op = ref { return true }; return false }`
- Line 44-46 `taskURL`: signature `id: String`; body
  `Int(id).map { baseURL.appendingPathComponent("work_packages/\($0)") }` (nil for non-numeric, not a crash).
- Lines 58-75 `createTimeEntry`: `taskID: String`, pass
  `workPackageID: try opTaskID(taskID)` (both the primary call and the 422
  fallback call at lines 71-73).
- Lines 77-84 `updateTimeEntry`: same conversion.
- Lines 98-100 `addTaskComment`: `taskID: String`, `id: try opTaskID(taskID)`.
- Lines 105-123 `OPPageRecognizer`: rename to the new protocol shape, wrap:
  `OPURLParser.taskID(...)` results in `.op($0)` via `.map(TaskRef.op)`.

## 6. SyncEngine — Sources/andeyeTTCore/SyncEngine.swift

- Line 26: `guard case .op(let taskID) = session.task else { continue }` →
  ```swift
  guard backend.owns(session.task),
        let taskID = session.task.backendTaskID else { continue }
  ```
  (`.local` fails `owns` for every backend; an un-owned remote session stays
  queued for its own backend — see §0. Do NOT markPushed it.)
- Lines 36-38: `createTimeEntry(taskID: taskID, ...)` now passes the String —
  no other change; the sub-60s short-circuit (lines 27-33) and the orphan
  rollback (lines 44-53) are ref-agnostic already.

## 7. Attribution + recognizer plumbing — Sources/andeyeTTCore/Attributor.swift

- Line 77: rename `lastOpenedOPTask` → `lastOpenedBackendTask` (private; also
  used at 121, 129, 167-168).
- Lines 120-124 (URL path):
  ```swift
  if let url = signal.tabURL, let ref = recognizer.taskRef(inURL: url) {
      lastOpenedBackendTask = ref
      let c = Candidate(target: .task(ref), score: Self.inferredCeiling)
      ...
  ```
- Lines 127-133 (title/PWA path): same shape with `taskRef(inTitle:)`.
- Lines 159-166 (`noteDwell`): the two early-return probes switch to
  `taskRef(inURL:) != nil` / `taskRef(inTitle:) != nil`.
- Lines 307-315 (`explain` URL + title arms) and 335-339 (`bestURLTarget`):
  same mechanical rename; `bestURLTarget` returns `.task(ref)` directly.
- Lines 26-35 (`AttributionExplanation.Source`): keep the case names
  `.opTaskURL` / `.opTaskTitle` (rawValues are not persisted, but the rename is
  churn for nothing pre-Xero-recognizer). Optionally soften the UI copy at
  TimelineView.swift:1236-1237 ("Backend task URL in the tab") — one string
  edit, cosmetic.

Everything else in the attribution stack (pins PinRule.swift:94-97, email rules
EmailMatch.swift:71-78, LearningStore targets, MinuteResolver, SessionTracker,
TaskRanker) stores `TaskRef`/`Target` opaquely — no edits; they work for
`.remote` the moment it exists.

## 8. App layer — Sources/andeyeTTMac/AppController.swift (+ UI)

- **433-434** (task-note routing in `wireTracker`):
  `if let taskNote, case .op(let wpID) = s.task { ... postTaskComment(wpID:...) }`
  → `if let taskNote, let tid = s.task.backendTaskID { Task { await self.postTaskComment(taskID: tid, note: taskNote) } }`
- **981-990** `postTaskComment(wpID: Int, ...)` → `postTaskComment(taskID: String, ...)`;
  add an ownership guard: `guard let backend, backend.owns-compatible` — concretely,
  since the caller can't cheaply build a TaskRef here, pass the ref instead:
  `private func postTaskComment(ref: TaskRef, note: String) async` with
  `guard let backend, backend.owns(ref), let tid = ref.backendTaskID else { return }`.
  (Caller at 433-434 then passes `s.task` — cleaner than the tid plumbing above; pick this shape.)
- **780-783** `name(of:)` fallback: replace the two lines
  `if case .op(let id) = ref { return "WP #\(id)" }; return "Leisure"` with
  `return ref.isRemote ? ref.fallbackLabel : "Leisure"`.
- **1480-1497** (timeline-edit push): `if case .op(let wpID) = session.task, let entryID..., let backend {` →
  `if let backend, backend.owns(session.task), let taskID = session.task.backendTaskID, let entryID = session.opTimeEntryID {` and pass `taskID: taskID`.
- **1648-1665** (`coalesceAdjacent` in-place patch): same transform as 1480
  (`case .op(let wpID) = survivor.task` → owns + backendTaskID).
- **1805-1809** `taskWebURL(id: Int)` → `taskWebURL(id: String)` (pass-through
  to `backend?.taskURL(id:)`).
- **1818-1825** timesheet resolver: `if case .op(let id) = ref { return ("Task #\(id)", nil) }`
  → `if ref.isRemote { return (String(ref.fallbackLabel), nil) }` (keep the
  "(deleted local task)" arm).
- **1849-1861** `refreshTasks` recency carry-over: keyed by `ref` — no edit
  needed; works when `fetchTasks()` starts returning `.remote` refs.

UI (Sources/andeyeTTUI):

- **SettingsView.swift:383-385** `openInOP(_ wp: Int)` calls
  `controller.taskWebURL(id: wp)` → `taskWebURL(id: String(wp))`. (This is the
  OP duplicate-reconcile detail row — `OPTimeEntry.workPackageID` is genuinely
  an Int, the String conversion at the call is correct, don't touch OPTimeEntry.)
- **TimelineView.swift:510 and 940**: `.op(0)` placeholder refs for the draft
  editor / picker binding. Leave them — they're "no real selection yet"
  sentinels resolved before save; a `.remote("")` variant would be worse. Add
  a `// placeholder sentinel; never journalled` comment if absent.

Integration harness Sources/andeyeTTIntegration/main.swift:113-131 exercises a
real OP instance — `.op` stays correct there; it must still compile after the
seam change (its stub task list construction doesn't touch the changed
signatures, but `swift build` will confirm).

## 9. Check list — Sources/andeyeTTCoreChecks

Add to existing suites (registration table at main.swift:47-77); new checks,
mechanical to write:

ModelsChecks.swift (suite "Models"):
1. `.remote` Session round-trips through JSON (mirror of check at ModelsChecks.swift:26-31).
2. **Wire-format freeze**: raw literals `{"op":{"_0":7}}`, `{"local":{"_0":"<uuid>"}}`,
   `{"remote":{"_0":"abc-123"}}` each decode to the exact case; encode of
   `.remote("abc-123")` contains `"remote"`. (This is the back-compat contract
   for journal rows, pins.json, emailrules.json, primed.json, and CloudKit
   revisions — the whole point of the additive-case decision.)
3. `backendTaskID` truth table (op → "7", remote → guid, local → nil);
   `isRemote`; `WorkTask.isLocalOnly` is false for a `.remote` task.
4. `storageKey` = "op:7" / "local:<uuid>" / "remote:<guid>".

StorageAndSyncChecks.swift (suites "JournalStore[InMemory]" + "JournalStore[SQLite]"
— both stores, same assertions, matching the existing conformance pattern):
5. A saved `.remote` session appears in `sessions(needingPushAtOrAbove:)`;
   `.local` still never does.
6. SQLite only: raw `SELECT is_op FROM sessions WHERE id = ?` returns 1 for a
   `.remote` row (freezes the column semantics, not just the query behaviour).
7. `latestEndByTask` returns the `.remote` ref keyed correctly.

SyncEngine (StorageAndSyncChecks.swift, next to the existing push checks ~line 327):
8. Stub backend owning `.remote`: `pushEligible` pushes a `.remote` session,
   the stub receives the GUID string as `taskID`, session marked pushed with
   the returned entry id.
9. Ownership skip: same stub + an eligible `.op` session → not pushed, not
   marked, no throw; return count excludes it.

AIAssistChecks (in StorageAndSyncChecks.swift ~line 428):
10. `classificationPrompt` lists a `.remote` task with its GUID id.
11. `parseResponse` maps a GUID string task value to `.task(.remote(guid))`
    via the new lookup (§10); an unknown task id is skipped like an unknown
    segment uuid (don't fail the batch).

AttributorChecks:
12. A stub `BackendPageRecognizer` returning `.remote("g-1")` for a URL: attribute()
    yields `.task(.remote("g-1"))` at `inferredCeiling`, and dwell-priming
    (`noteDwell` then a non-backend surface) primes to that ref.

SettingsChecks:
13. `AndeyeSettings.activityOverrides` and `taskColours` keyed by a `.remote`
    ref round-trip through JSONFileStore encode/decode.

## 10. AI assist — Sources/andeyeTTCore/AIAssist.swift

Today the prompt lists only `.op` tasks (lines 29-33) and the reply grammar is
int-or-"do-not-track" (lines 41-45, 113-128, 159).

- Lines 29-33: list every remote task:
  `for t in tasks { if let id = t.ref.backendTaskID { lines.append("#\(id): ...") } }`
  (`.local` stays excluded — unchanged scope).
- Line 43: reply spec becomes
  `{"assignments": [{"segment": "<uuid>", "task": <task id (number or quoted string) or "do-not-track">}]}`.
- `TaskValue` (113-128): add `case guid(String)` — a decoded String that isn't
  "do-not-track" becomes `.guid(s)` instead of throwing.
- `parseResponse` (130-163): new parameter
  `taskRefByID: [String: TaskRef]` (caller builds it as
  `Dictionary(uniqueKeysWithValues: tasks.compactMap { t in t.ref.backendTaskID.map { ($0, t.ref) } })`).
  Mapping: `.id(n)` → `taskRefByID[String(n)]`, `.guid(s)` → `taskRefByID[s]`;
  a miss returns nil from the compactMap (skip, don't reject the batch —
  same policy as unknown segment uuids, lines 151-157).
- Call sites: AppController.swift:1706 (prompt — no signature change) and
  1769-1771 (`ingestAIResponse` — pass the lookup built from `taskCache`);
  existing checks at StorageAndSyncChecks.swift:428-474 gain the parameter.

Note: `.id(n)` → lookup (not blind `.op(n)`) also fixes the latent bug where a
hallucinated id fabricated a nonexistent `.op` task — mention in the commit.

## 11. Ranking / pick-list impact (mostly "verified none")

- TaskRanker.swift: fully ref-opaque (`Set<TaskRef>` dedupe at 69-70, scoring
  on status/recency/assignee). `.remote` tasks rank identically — PROVIDED the
  backend conformer maps its statuses into the user's `statusOrder`
  vocabulary; a Xero status outside it just scores statusScore 0 (bottom
  prior, recency still works). Contract note for the pro conformer, no core edit.
- `fullPickList` (AppController.swift:809-813), popover + filter
  (PopoverView.swift:567, 617), FuzzyMatch: subject/ref-opaque, no edits.
- TimeAggregator.swift:58-61 `fallbackLabel`: replace body with
  `ref.fallbackLabel` from §1b (delete the local duplicate); `isLocal` at 53-56
  stays (grouping under "Personal" is a `.local`-only behaviour, `.remote`
  falls to the task's real project or "Other" — correct).
- DuplicateReconcile.swift:105 (`s.task == .op(wp)`): reconcile is structurally
  OP-only (`OPTimeEntry.workPackageID: Int`, listTimeEntries returns
  `RemoteTimeEntry = OPTimeEntry`). Leave as-is; generalising read-back
  reconciliation is a separate work item — add a TODO.md entry
  `[ ] generalise DuplicateReconcile/RemoteTimeEntry beyond OP (Xero read-back)`.

Drift-check greps before executing:
`grep -rn "case .op\|\.op(" Sources --include=*.swift` and
`grep -rn "taskID: Int\|taskID(in" Sources` must come back empty of unlisted
production sites when done (checks/integration constructing `.op(...)` test
data are fine and expected to remain).

## 12. Back-compat statement (journalled rows and friends)

- **Old data, new build**: decodes unchanged everywhere — journal `json`
  column, `$.task` extracts, primed.json, pins.json, emailrules.json,
  settings (activityOverrides/taskColours), CloudKit revisions. Guaranteed by
  the additive synthesized-Codable case; frozen by §9 check 2.
- **New data, old build** (downgrade, or a second device on an older build
  pulling CloudKit revisions containing `.remote`): `TaskRef` decode THROWS.
  Settings survive (lenient per-field decode, Settings.swift:165-201 — the
  overrides map falls back to default); pins.json/emailrules.json decode
  wholesale and would reset to empty on that build; a journal row's decode
  failure surfaces as a thrown read. Accepted: `.remote` values can only be
  CREATED once a GUID backend is connected, which ships in the pro build
  AFTER this model change is everywhere. Sequencing rule: **land + release the
  model change (this plan) at least one Community release before any backend
  can mint `.remote` refs.** Record this in CHANGELOG and in
  docs/superpowers/specs/2026-07-02-sync-design.md (one line under "Record
  model": Session.task may hold `.remote`; devices must run a TaskRef-remote-
  aware build before a GUID backend is enabled).

## 13. Execution order (each phase compiles + checks green before the next)

1. §1 Models + §2 storageKey + Models/Settings checks (§9: 1-4, 13).
2. §3 journal semantics + store checks (§9: 5-7).
3. §4 seam + §5 OPBackend + `swift build` (integration target compiles).
4. §6 SyncEngine + ownership checks (§9: 8-9).
5. §7 Attributor/recognizer + check 12.
6. §8 AppController/UI label + signature sites.
7. §10 AIAssist + checks 10-11.
8. §11 TODO.md entry (DuplicateReconcile), §12 doc lines, CHANGELOG entry —
   same commit as the final code phase per the TODO/CHANGELOG convention.

Verification each phase: `swift build && swift run andeyeTTChecks`
(Command Line Tools only — no XCTest; the checks harness IS the test suite).
Pro repo (`pro/`, XeroClient.swift already present, no TaskBackend conformer
yet) builds against the widened seam afterwards; the XeroBackend conformer
(WorkTask ref `.remote(task.taskId.lowercased())`, minutes-unit durations,
`owns` = `.remote` only, NoPageRecognizer initially) is a separate pro-repo
plan and NOT part of this execution.

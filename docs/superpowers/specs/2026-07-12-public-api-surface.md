# Public API surface

The package ships several library targets (`timeandeyeCore`, `timeandeyeStore`,
`timeandeyePhone`, `timeandeyeMac`, `timeandeyeUI`, `timeandeyeTheme`). Only a
small, deliberate slice of what those targets contain is meant to be called
from *outside* the package. This spec defines that slice, the access-control
rule that keeps it small, and how a third party extends the app.

## Why seal the surface

Before this change almost every cross-module type was `public`, which conflated
two very different audiences: the many types that are `public` only because a
sibling target in the same package reads them, and the few that a genuinely
separate package (a paid connector build, the iOS companion app) links against.
The first group does not need `public` at all – Swift's `package` access
(tools 5.10) makes a declaration visible to every target in this package while
keeping it invisible to anything that merely depends on the package. Demoting
the first group to `package` shrinks the compiled public API to exactly the
contract below, so an external consumer sees the seam and nothing else, and an
internal refactor no longer looks like a breaking change.

## The three-tier public contract

Everything that stays `public` falls into one of three tiers. Each `public`
declaration carries a doc comment naming which tier it belongs to and who
consumes it.

### 1. The connector seam (`timeandeyeCore`)

The extension point for a task-list / timesheet backend. A backend conformer
lives in its own package and links `timeandeyeCore`; these are the types it
speaks:

- `TaskBackend` (the protocol a connector conforms to) and its default-method
  extension, `HTTPTransport` (the injected network seam), `BackendPageRecognizer`
  and `NoPageRecognizer` (task-page recognition), `BackendClass`,
  `BackendRegistry` (and its `register` methods), `BackendEntitlementRequirement`.
- The value types those signatures name: `WorkTask`, `TaskRef`, `RemoteTimeEntry`,
  `RemoteEntryID`, `TimeActivity`, `AmendmentError`, `PermanentPostError`.
- The finance-mapping surface a connector reads: `FinanceMapping` and
  `FinanceMappingStore`.
- The posting engine a host app drives: `SyncEngine`.

### 2. The licence / entitlement family (`timeandeyeCore`, `timeandeyeUI`)

The offline licence-verification and connector-entitlement contract, kept stable
across repositories even where this repo does not itself call every member:
`License`, `LicenseTier`, `LicenseError`, `LicenseVerifier`, `LicenseSigner`,
`EntitlementDecision`, `EntitlementDenialReason`, and `AndeyeScenes` (the scene
set a host executable wraps as its `@main`). These are declared public because a
separate package mirrors their shape; their doc comments say so.

### 3. The iOS companion surface (`timeandeyePhone`, `timeandeyeCore`)

The iOS app is a separate build that links `timeandeyeCore` and
`timeandeyePhone`. It drives `PhoneController` (all of its published members and
methods) and reads the Core value/logic types those members return – the
attribution/timeline pure-logic types (`TimeAggregator`, `PieGeometry`,
`TimePeriod`, `TimelineMath`, `Session`) plus the two settings fields the phone
UI binds. Because the command-line-tools build on the package's own CI cannot
compile an iOS target, this tier is protected by analysis: a symbol the iOS
sources touch stays `public` even though no in-package build would flag its
removal.

Beyond these three tiers, the public API also includes the transitive **signature
closure** the compiler requires: a `public` declaration may not expose a
`package` type in its signature, so every type named by a public member above is
itself public.

## The rule for new declarations

> `package` is the default access level for a new declaration. Use `public` only
> when an external consumer needs it, and say which one in a doc comment – the
> connector seam, the iOS companion, or a declared cross-repo contract.

A declaration with no such consumer stays `package` (or narrower). This keeps the
public surface honest: reading the public API tells you the whole external
contract, and nothing leaks into it by the accident of being read one module
over.

Re-widening a `package` declaration back to `public` is an *additive* change –
nothing outside the package can have depended on it while it was sealed – so it
is safe to do the day a real external consumer appears (for example when a
connector build grows a host-app target that wraps the macOS UI). Do it then,
deliberately, with the doc comment that names the new consumer; do not widen
speculatively.

## Extending the app with your own backend

The supported extension point is the `TaskBackend` seam. To add a backend
(another project tracker, a timesheet service):

1. Create your own Swift package that depends on this one and imports
   `timeandeyeCore`.
2. Declare a type that conforms to `TaskBackend`. Implement the task-list reads
   (`fetchTasks`, `fetchMe`, `fetchActivities`), the time-entry writes
   (`createTimeEntry`, `updateTimeEntry`, `deleteTimeEntry`, `listTimeEntries`),
   and the page-recognition hook (`pageRecognizer`, returning your own
   `BackendPageRecognizer` or `NoPageRecognizer` when your pages carry no task
   identity). Throw `PermanentPostError` for a rejection that can never succeed
   and `AmendmentError` when an edit cannot proceed as asked, so the engine can
   route the row correctly instead of retrying forever.
3. Inject an `HTTPTransport` for the network so your conformer stays testable
   without hitting a live server.
4. Register the backend with a `BackendClass` (`.pm` for a project tracker that
   receives all owned time, `.finance` for one that receives billable time). A
   backend that requires a licence declares a `BackendEntitlementRequirement`
   and registers through the entitlement-gated `register` overload.

The journal on the device stays the source of truth throughout: your conformer
translates between that journal and your service, and never becomes one itself.

# Billable flag + multi-backend fan-out – design

Status: DESIGN (no code in this commit). Spec date 2026-07-06. Seeds a /vs
run once Martin has answered the open questions.

andeye tracks time locally (SQLite journal = source of truth) and pushes
confirmed sessions through the `TaskBackend` seam. Today exactly one backend
can be connected (OpenProject, or standalone = none). This spec adds: a
project-level billable flag with per-task override (in andeyeTT, the
community edition); backend CLASSES so a PM backend receives all confirmed
time while a finance backend receives only the billable subset; and the
multi-backend fan-out architecture (per-entry per-backend posting ledger,
per-project routing, failure isolation) that lets one instance post the same
session to OpenProject AND Xero simultaneously – and, at end-game, to
several backends including duplicates of the same type (two Xero orgs, two
OP instances).

## 0. Open questions for Martin (answer before /vs build starts)

1. **Default billability for an unflagged project** – recommend
   non-billable: nothing ever reaches an invoicing backend unless someone
   deliberately opted the project in. The failure mode of the opposite
   default is invoicing a client for internal time. Confirm.
2. **Flag changes are prospective only** – recommend yes: toggling a
   project billable/non-billable affects entries not yet posted; entries a
   finance backend already holds are never retracted by andeye (un-invoicing
   is a human act in the finance app). Confirm, or ask for a bounded
   "re-evaluate unposted history" action too.
3. **Xero Core tier connection count** – the published material confirms
   Starter = 5 connections free and Core ≈ US$22/month with 10 GB egress,
   but not how many connections Core includes; the number sits behind the
   developer-dashboard login.
4. **Xero connector cost is recurring** – Xero's API fees are
   per-connection costs from March 2026 and connector maintenance is
   ongoing (see the costs section).
5. **Customer-supplied Xero app escape hatch** – Xero's "internal
   innovation" use stays free, so a customer who registers their own Xero
   app and pastes its credentials into andeye costs andeye nothing. In
   scope for the v1 connector (recommend: yes, it is mostly a credentials
   field) or later?
6. **v1 backend cap** – recommend one PM + one finance active per instance
   in v1, with the data model N-ready (see scope section). Martin runs
   multiple companies himself, so confirm he can live with one Xero org in
   v1, or the TaskRef identity work (below) pulls forward.

## 1. What the code says today (investigation)

- **One backend, hard-wired singular.** `AppController`
  (Sources/andeyeTTMac/AppController.swift) holds
  `private var backend: (any TaskBackend)?` – nil means standalone.
  `SyncEngine` (Sources/andeyeTTCore/SyncEngine.swift) is constructed with
  exactly one journal + one backend and throws on the first push failure,
  leaving later sessions queued. `PhoneController` and the integration
  harness mirror the same one-engine-one-backend shape.
- **Single-slot posting record.** `Session`
  (Sources/andeyeTTCore/Models.swift) carries `pushedToOP: Bool` and one
  `opTimeEntryID: RemoteEntryID?`; the SQLite schema
  (Sources/andeyeTTStore/SQLiteJournalStore.swift) mirrors this as `pushed`
  and `is_op` columns. A session can therefore record having been posted to
  at most ONE backend. This is the load-bearing refactor: posting the same
  session to OP and Xero is impossible until the single flag becomes a
  per-backend ledger.
- **Ownership is exclusive routing.** `TaskBackend.owns(_:)` plus the
  `TaskRef` cases (`.op(Int)`, `.remote(String)`, `.local(UUID)`) route a
  session to the single backend that owns its task; un-owned sessions are
  skipped silently. Fan-out to a finance backend must NOT go through
  `owns` – a session on an OP task still needs to reach Xero.
- **TaskRef has no instance identity.** `.op(Int)` is a bare work-package
  id: two OP instances would collide on id 42, and `.remote(String)` GUIDs
  carry no org identity either. Safe duplicate-type backends therefore
  need backend-qualified task identity (or ledger/routing scoping that
  supplies it) – this is the expensive part of the end-game and the reason
  v1 caps at one backend per class.
- **Projects are display strings, not entities.** `WorkTask.project` is the
  project TITLE only (`OPClient` maps `_links.project?.title`);
  `LocalTaskDef.project` is a free-text name. There is no stable project
  key to hang a flag on yet – the OP conformer must start capturing the
  project id from the work package's project link, and local projects key
  by their name.
- **Good foundations already in place.** The seam already speaks String
  entry ids for GUID backends, `Session.opTimeEntryID` was widened
  2026-07-02, `supportsTaskComments` already models Xero's missing comment
  endpoint, `DuplicateReconcile` reads backend entries back, `SyncEngine`
  already rolls back a created entry when the journal mark fails (the
  create-then-mark crash window), and `License.swift` gates paid backend
  plugins. The 2026-07-02 sync design gives every synced record HLC + a
  single-pusher lease, which the posting ledger must join.

Verdict: simultaneous OP + Xero is a REFACTOR of the posting record and the
sync loop, not of the seam. `TaskBackend` itself barely changes; the
journal's "was this pushed" model changes shape.

## 2. The billable flag (tri-state, project cascade)

- **Project flag**: every project (OP project, local project name, later a
  Xero project) is billable or non-billable. Default per open question 1.
- **Task flag**: tri-state – inherit (default) / billable / non-billable.
  A task's EFFECTIVE billability = its own flag if manually set, else the
  project's.
- **Cascade + alert**: toggling the project flag changes the effective
  state of every inheriting task. Tasks whose flag was manually set are
  left exactly as they are, and the user is told so in the same gesture:
  "Project marked billable – 3 tasks kept their manual setting", with a
  one-click "Align all" that clears those overrides back to inherit (and an
  undo). No silent divergence, no forced flattening.
- **Where the flags live**: user metadata beside `taskColours` and
  `activityOverrides` in `AndeyeSettings` – keyed by a stable project key
  (backend-qualified project id for OP; name for local) and by
  `TaskRef.storageKey` for task overrides. They join the multi-device sync
  set as whole-record LWW like `LocalTaskDef`/`Pin` (low churn), per the
  2026-07-02 sync design.
- **Evaluation time**: effective billability is evaluated at POST time per
  backend, not stamped onto the session at tracking time. Corrections made
  before the push therefore behave as the user expects, and prospective-
  only semantics (open question 2) fall out naturally: the ledger records
  what was actually posted where.
- **UI story**: the community timeline and pie can show/filter billable vs
  non-billable time from day one – the flag pays for itself before any
  finance backend exists (timesheet export can carry a billable column
  too, via TimesheetExport).

## 3. Backend classes: pm and finance

Every configured backend declares a class:

- **pm** (OpenProject): receives ALL confirmed time – the complete PM
  record, billable or not, exactly as today.
- **finance** (Xero; later FreeAgent, QuickBooks): receives ONLY sessions
  whose effective billability is billable AND whose project is routed to
  it. Non-billable projects are invisible to a finance backend in every
  sense – never posted, never listed in its mapping UI, never mentioned in
  its errors. Irrelevant projects simply do not exist as far as Xero is
  concerned.

A finance backend may still expose a task list (Xero Projects has projects
and tasks), so a user with no PM at all can run andeye against Xero alone –
class governs the FILTER on outbound time, not whether the backend can
provide tasks. This preserves the current "OpenProject today, Xero next"
single-backend story unchanged.

Cross-backend posting needs a mapping: a session on an OP task reaches Xero
via a per-project routing table – andeye project → Xero project (and a
default Xero task within it, since Xero time entries attach to a task).
This same table is what disambiguates duplicate-type backends at end-game:
routing is per project PER BACKEND, so "project Alpha → Xero org 1, project
Beta → Xero org 2" is the one mechanism serving both needs.

## 4. Multi-backend fan-out (the end-game architecture)

- **Backend registry**: settings hold a LIST of backend descriptors – a
  stable backend id (UUID, minted at connect time and never reused), kind
  (openProject / xero / ...), class (pm / finance), display name,
  credentials reference (key store), and per-backend options. Today's
  single `opBaseURL` + one API key file migrates to the first entry.
- **Posting ledger**: a new journal table replacing the single
  `pushed`/`opTimeEntryID` slot – one row per (session id, backend id),
  holding state (pending / posted / failed / skipped), the remote entry id
  when posted, last error and attempt count when failed. The (session id,
  backend id) pair IS the idempotency key: a retry can only ever update its
  own row, so no retry path can double-post. `SyncEngine`'s existing
  rollback (delete the created entry if the journal mark fails) generalises
  per row, and `DuplicateReconcile` remains the belt-and-braces read-back.
  Migration: every existing pushed session becomes one posted row against
  the OP backend's new id; `Session.pushedToOP` survives as a derived
  compatibility view (the sync wire shape of existing rows is frozen by
  checks).
- **Fan-out loop**: the sync pass iterates backends; for each backend it
  selects sessions eligible FOR THAT BACKEND (certainty threshold, class
  filter, routing, no posted row yet) and posts them. Per-backend error
  state: one backend failing (Xero down, OP token expired) never blocks
  the others – its rows stay pending/failed and retry on the next pass.
  The sync design's single-pusher lease covers the whole ledger: one
  device posts, ledger rows sync like session records.
- **Duplicate-type backends**: safe once (a) the ledger and routing are
  keyed by backend id – they are, from day one – and (b) task identity is
  backend-qualified so two OP instances cannot collide on `.op(42)`. The
  TaskRef widening is deliberately deferred out of v1; the ledger schema
  never needs to change when it lands, which is what "N-ready" means here.

## 5. Edition split – the flag is andeyeTT, the connector is andeyePro

Decided: the billable flag ships in andeyeTT (community, AGPL), NOT in
andeyePro.

- OpenProject's Community edition already supports billable workflows –
  time tracking, per-user hourly rates and cost reports are free-tier
  features ([time and costs docs](https://www.openproject.org/docs/user-guide/time-and-costs/),
  [cost reporting](https://www.openproject.org/docs/user-guide/time-and-costs/reporting/)) –
  so the flag has real value to a pure community user today.
- The flag is Core data-model metadata. Forking the journal/settings schema
  between editions would be the most expensive split to maintain; the
  schema stays one.
- The community timeline and pie already tell the billable story once the
  flag exists (see the UI note in the flag section).
- The Pro boundary stays at the CONNECTOR: finance-class backends, their
  billable-only filtering and per-org routing ship with the Xero connector
  in andeyePro (gated exactly where `License.swift` already gates paid
  backend plugins).
- Funnel effect, named deliberately: community users who flag billability
  build the very dataset whose one-click payoff is the Pro upgrade.

## 6. Recommended v1 scope vs end-game

v1 (the /vs build this spec seeds):

- Billable flag, cascade, kept-their-setting alert, align-all + undo, and
  billable display in timeline/pie – all in andeyeTT.
- Posting ledger refactor + backend registry + fan-out loop in Core/Store –
  the schema is the expensive-to-fork part, so it lands NOW even though
  community runs one backend.
- One PM + one finance backend active per instance; finance connector
  (Xero) in andeyePro. Requirement 2 is thereby met in v1: the same
  confirmed session posts to OpenProject (all time) and Xero (billable
  subset) simultaneously.
- Stable project keys: OP conformer captures project ids; local projects
  key by name.

Deferred to end-game: N backends per class and duplicate-type backends
(two Xero orgs, two OP instances) – blocked only on backend-qualified
task identity and the routing/settings UI, not on any schema change.

The counter-argument, named: Martin himself runs multiple companies and is
therefore the first user who wants two Xero orgs – deferring the very
feature the founder needs risks the TaskRef shape ossifying further.
Response: the ledger and routing are backend-id-keyed from day one, so the
later lift is confined to TaskRef scoping plus UI; and one instance per
company (two Macs / two user accounts) is a workable interim for the one
known multi-org user.

# andeyeTT sync design — multi-master journal (CloudKit)

Decided 2026-07-02 (Martin): go multi-master immediately, not Mac-owned +
iOS-commands. An iOS-only user has no Mac to own the journal, so the journal's
source of truth becomes the *synced set*, with every device holding a full
local replica (SQLite as today) and merging deterministically.

## Principles

- **Local-first stays.** Every device works fully offline against its SQLite
  replica; sync is convergence, not availability.
- **Deterministic convergence.** Two devices that have seen the same set of
  record revisions MUST hold identical journals, regardless of arrival order.
  All merge logic is pure Core, checked in the harness — CloudKit is just the
  pipe (a `SyncTransport` seam, like `HTTPTransport`).
- **Never lose time silently.** Overlap resolution trims or drops the
  *lower-authority* record only when a higher-authority record covers that
  time; deliberate human input always beats automation (mirrors the
  DuplicateReconcile policy: never two records for one point in time).
- **One backend pusher.** Only one device per account pushes to the PM/finance
  backend (else two devices both POST the same eligible session → duplicate OP
  entries — the bug class we just closed on one device). Enforced by a pusher
  lease record; default: the Mac, or the sole device for iOS-only users.

## Clock: HLC

Wall clocks across devices can't order edits (iPhone vs Mac skew). Each device
runs a **hybrid logical clock** (physical ms, counter, deviceID). Every local
mutation stamps `hlc = clock.tick()`; every received remote stamp advances the
clock (`receive`). Total order: (physicalMillis, counter, deviceID).

## Record model

Synced entities, each a revisioned record keyed by its stable id:

- **Session** (the journal slice) — id: existing UUID. Carries `origin`
  (authority class) and the usual fields; `pushedToOP`/`opTimeEntryID` sync
  with it (only the pusher writes them).
- **LocalTaskDef**, **Pin**, **EmailRule** — whole-record LWW (low churn).
- **Live state** (current task, certainty, since, device) — ephemeral,
  latest-wins, never merged into the journal.
- Learning store: NOT synced in v1 (big blob, per-device learning is
  tolerable; revisit as mergeable counts later — the counts are CRDT-friendly
  since increments commute).

Per-record revision metadata: `hlc` (last writer), `origin`, `deleted`
(tombstone — deletes must travel; tombstones retained ≥ 90 days).

## Merge semantics

1. **Record-level: last-writer-wins by HLC**, including deletes (a tombstone
   with newer HLC beats an edit; an edit with newer HLC resurrects — that's
   the user re-instating on device B what they deleted on A, in that order).
2. **Set-level: deterministic overlap resolution** (sessions only) — a
   **derived view, never synced**. The raw revision set is the truth replicas
   exchange; every device derives the identical normalised journal from it
   (UI, aggregation and the backend pusher read the view). Persisting or
   pushing derived trims would put different content under one HLC on two
   devices — the one way LWW can diverge — so we never do.
   - Authority ladder `origin`: **edited (2) > manual (1) > auto (0)** —
     a timeline edit beats an iPhone manual timer beats Mac auto-tracking.
   - Priority order: origin desc, then HLC desc, then id (total order).
   - Walk in priority order; each session is trimmed against the time already
     claimed by higher-priority sessions. Fully covered → surfaces as deleted
     in the view. A middle overlap (winner strictly inside the loser) trims
     the loser to its larger remaining side in v1 — no nondeterministic
     splits; the windows detail under the winner survives in spans as usual.
   - Same-task butt-joins remain TimelineMath's local concern.
   Corollary: an HLC never changes without a content change (every local
   mutation re-stamps via tick()); equal HLC ⇒ equal content.

## Change flow

Each replica keeps a `dirty` flag per record (set on local mutation, cleared
on push). Sync cycle: push dirty revisions → pull remote changes since the
saved server change token → record-merge → overlap-normalise → apply to
SQLite → notify UI. CloudKit private DB, one custom zone
(`CKFetchRecordZoneChangesOperation` gives incremental tokens + push wakeups
via zone subscriptions). Conflicts CloudKit rejects (server newer) are re-
pulled and re-merged — our merge is the authority, CK is transport.

## The pusher lease

A single `pusherLease` record (deviceID + HLC heartbeat). A device only runs
`SyncEngine.pushEligible` while it holds the lease; it renews on each sync and
a device may claim a lease stale ≥ 24 h. UI: Settings shows "this device
pushes to OpenProject" with a takeover button.

## Schema/versioning

Every record carries `schemaVersion`. Unknown newer fields are preserved
round-trip (store raw JSON beside decoded fields, as the SQLite store already
does). CloudKit production schema is append-only — field removals happen in
code, never in the schema.

## Migration

Existing Mac journal: one-shot stamp of every row with `origin = .auto`
(edited rows are indistinguishable historically — acceptable), `hlc =
tick()` in row order, `dirty = true`; first sync uploads all. Fresh iOS
install pulls the zone.

## Failure modes considered

- **No iCloud account** → local-only mode, sync UI hidden (unchanged app).
- **Clock skew** → HLC absorbs it; a device with a wildly-forward clock can
  win LWW unfairly but never corrupts (bounded: receive() caps drift adoption).
- **Two devices tracking simultaneously** → overlap ladder; both stretches
  survive where they don't collide, deliberate input wins where they do.
- **CloudKit outage/quota** → replicas diverge until it heals; no data loss.

## Build order (Core-first, CloudKit last)

1. `HLC` + `SessionRevision` + LWW merge + overlap resolver — pure, checked.
2. Store: revision columns + dirty tracking + change-log queries (SQLite +
   InMemory, conformance-checked).
3. `SyncSession` orchestrator against a mock `SyncTransport` — full sync
   cycles, conflict/resurrect/tombstone scenarios as checks.
4. CloudKit adapter (Mac first) — thin, no logic beyond record⇄CKRecord
   mapping. Needs real signing identity + iCloud entitlement (make-app.sh
   gains a provisioning path; blocked on the Apple account identity).
5. iOS app consumes the same stack.

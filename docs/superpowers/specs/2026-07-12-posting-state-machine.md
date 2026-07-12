# Posting – the money state machine

Where a slice's money is lives in exactly one place: the posting ledger, one
row per **(session, backend)** – the cell. This spec defines the cell's
states, every legal transition, and the invariants the code must keep. The
journal's `pushedToOP`/`opTimeEntryID` pair is a legacy *mirror* of the
primary-pm cell, kept for the timeline's patch/delete surfaces; it is never
the source of truth.

## The cell

State: `∅` (no row – eligible when the session qualifies), `inflight`
(intent recorded, wire call may be in progress or may have died),
`posted` (live remote entry, `entryID` set), `failed` (retryable),
`stuck` (30+ attempts, waits for the retry gesture), `skipped` (terminal by
policy), `retracted` (deliberately removed remotely), `diverged` (parked:
local truth and a frozen/locked remote entry disagree – a human resolves at
invoicing time). Plus `entryID` and `lockedInvoiceRef`.

Two decode/fail-closed rules protect the cell across versions and errors: an
unknown persisted state decodes as `posted` (never-double-post bias), and an
unknown state blocks eligibility in SQL. Sub-minute policy is split on
purpose: a session whose **raw** duration is short gets a terminal `skipped`
row; one trimmed short only by overlap resolution gets **no row**, so
restoring the covering slice re-bills it.

## Who may touch the wire

The sync engine owns the wire. Its passes are intent-first (`inflight` row
committed before the create call), crash-reconciled (`reconcileInflight`
adopts, fails, or skips dead intents), resurrection-guarded (a touched
`posted` row missing at the backend demotes to `failed`, never clears), and
lock-honouring (a row with `lockedInvoiceRef` is never amended, never
retracted – drift on a locked row surfaces once and parks `diverged` when
frozen).

User paths (timeline edit, delete, reassign, coalesce, refile, reconcile)
express *intent*. Where they currently make wire calls directly, they must
obey the same two laws the engine does:

- **The lock law.** `lockedInvoiceRef != nil` freezes the remote entry
  against every path – engine and user alike. A user may always change the
  *local* truth (their word about where time went); the locked remote entry
  is left untouched and the cell parks `diverged`, surfacing on
  posting-health for resolution at invoicing time. No path deletes or amends
  a locked entry, ever.
- **The compensation law.** Every sever of a live linkage has exactly one
  compensation: the remote entry is deleted now, handed to the engine for
  retraction, or parked `diverged`. A failed remote delete may not clear the
  cell – the row stays (`failed`, `entryID` retained) so the engine retries;
  clearing on failure orphans a live backend entry that no scan can ever see
  again.

## Deleting a session

Deleting a session locally retracts its money everywhere: the pm entry and
any **unlocked** finance entry are deleted/handed to retraction; a **locked**
finance entry parks `diverged`. Billed time must never quietly outlive its
session.

## Concurrency

`syncing`/`syncRequested` serialise pass against pass, not pass against
mutation: a pass reads its queue, then awaits the network, and a user
mutation can land in between. Any mutation-side ledger write that can race a
pass snapshot must therefore be a compare-and-set
(`setPostingRecord(unlessState:)`) – requarantine already is; a row-clear
must not overwrite `inflight` (the engine owns an in-progress intent; express
the intent and let reconcile settle it).

## The invariants

`PostingMachineChecks` pins these, example-style where one scenario suffices
and as a bounded model check (scripted backend, interleaved transition
sequences, invariants asserted after every step) where ordering matters:

- **M1 one live entry** – a cell never has two live remote entries; creates
  happen only from `∅`/`failed`/`stuck` and always via `inflight` first.
- **M2 lock immutability** – no transition sequence containing any user path
  amends, deletes, or unlocks-and-forgets a locked cell's remote entry;
  local edits on a locked cell always end `diverged`, counted on
  posting-health.
- **M3 compensation pairing** – after any sever, either the remote entry is
  gone, a row with its `entryID` survives in a retryable state, or the cell
  is `diverged`. Never a cleared cell with a live remote entry.
- **M4 session-delete totality** – after deleting a session, no backend
  holds an unlocked live entry for it; locked entries are `diverged`.
- **M5 mirror coherence** – after every pass, the journal mirror equals the
  primary-pm cell (`pushedToOP ⟺ posted`, `opTimeEntryID = entryID`); a
  best-effort mirror write that failed is re-asserted by the next pass.
- **M6 sub-minute split** – raw-short ⇒ terminal `skipped`; trimmed-short ⇒
  no row (re-billable on restore).
- **M7 fail-closed** – unknown states block eligibility and decode as
  `posted`; a migration failure pauses the pass rather than half-running.
- **M8 backend independence** – one backend's cell never gates another's
  eligibility; finance and pm rows for one session evolve independently
  (subject to M4).

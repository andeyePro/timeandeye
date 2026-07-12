# Multi-device posting correctness – design

Status: DESIGN (no code in this commit). Spec date 2026-07-07. Written by the
Fable review session from findings F8–F19 (a prior internal review); resolves them
into one buildable architecture. Read with `2026-07-02-sync-design.md` (the
journal CRDT this builds on) and `2026-07-06-billable-flag-multibackend.md`
(the posting-ledger fan-out this hardens).

## The problem, in one sentence each

- F8: the overlap-resolved journal view exists (`SessionMerge.resolveOverlaps`)
  but nothing reads it — pusher, UI and aggregation read raw rows, so
  cross-device overlapping sessions double-count and double-post.
- F9: the posting ledger is per-device while the journal syncs — a second
  device with the same backend registered re-posts everything; the only
  accidental guard (the legacy pushed flag riding inside the synced session)
  is pm-only, racy, and best-effort.
- F10: `markPushed` re-stamps the session's HLC, so posting bookkeeping
  competes with user edits in whole-record LWW — an edit can silently vanish
  or the pushed flag can silently revert.
- F11: every edit surface amends the primary PM backend only; a posted
  finance entry is never updated/deleted after any edit.
- F12/F13: a crash between backend-create and ledger-write re-posts; a
  tombstone-resurrected session can claim `.posted` for an entry that no
  longer exists.
- F19: one permanently-failing session blocks a backend's whole queue
  forever (no attempt cap, no permanent/transient distinction).
- F18: the seam hands finance backends raw task ids; the OP→Xero mapping is
  designed but unowned.

## Invariants (what "correct" means)

1. At most one external entry exists per (session, backend-connection),
   across any number of devices, crashes, retries, or sync races.
2. External entries CONVERGE to the overlap-resolved journal: after edits,
   trims, deletes, reassigns — from any device — the backend eventually holds
   what the merged journal says, or visibly reports why it can't (frozen).
3. Posting state never rides inside the LWW-merged session record while sync
   is on. Bookkeeping must not be able to erase an edit, and an edit must not
   be able to erase bookkeeping.
4. No silent stalls: a session that will never post is terminal-with-reason,
   visible, and never blocks the sessions behind it.

---

## D0. Journal-sync anti-entropy prerequisites (fixes F21, F22 — found after
the main review; everything below assumes a convergent journal, which the
current transport + syncer pair does not quite guarantee)

1. **Re-assert local wins.** `JournalSyncer.sync()`: when the merge keeps a
   LOCAL revision against a DIFFERENT remote (`winner == local`,
   `local != remote`), re-mark it dirty so the push phase re-asserts it.
   Without this, CloudKit's `.allKeys` save policy (unconditional overwrite,
   no change-tag check) lets a stale concurrent push overwrite a newer server
   record, and the newer replica — whose dirty flag was already cleared —
   never re-pushes: A holds the edit, server and B hold the stale version,
   PERMANENTLY, until an unrelated re-stamp. One-line policy change;
   idempotent; converges in one extra round-trip; no-op on echoes.
2. **Chunk pushes.** `CloudKitSyncTransport.push()` sends all dirty rows in
   one `modifyRecords` call; CK caps ~400 records/op. Enabling sync stamps
   the WHOLE backlog dirty, so a mature journal throws `limitExceeded` on the
   first cycle and every retry — sync never starts. Chunk at ≤200; per-batch
   zone atomicity keeps clearDirty semantics safe.
3. **Surface decode drops.** `pull` compactMaps undecodable records away; a
   new TaskRef case makes old builds silently lose those sessions from view.
   Count and surface ("N sessions from a newer andeye version aren't visible
   on this device") rather than dropping silently.

## D1. Wire the resolved view (fixes F8)

STATUS: IMPLEMENTED for posting + aggregation + export (overnight run,
2026-07-08). `JournalStore.resolvedSessions(from:to:)` /
`resolvedContribution(sessionID:)` with identity defaults (sync off =
byte-for-byte today) and sync-aware SQLite overrides; the engine bills each
session's resolved contribution (fully-covered ⇒ `.skipped`, never billed)
and snapshots postedStart/postedDuration onto the ledger row; pie
(Mac+phone) and timesheet export read the resolved view.
SessionMerge.resolvedContributions folds fragments back to their parent so
ledger rows stay keyed by stored session ids — no fragment-id rows exist.
DELIBERATELY still raw: timelineSessions (the timeline is the EDIT surface;
fragment-aware editing needs its own design), duplicate-reconcile, and all
edit paths (they operate on stored identity). ResolvedPostingChecks pins
criterion 1 + the covered-session case + the sync-off identity.

One read-side choke point in Core — `ResolvedJournal` (name flexible): load
the raw revisions whose `[start, end)` intersects the query window (the
existing `start < to AND end > from` query already captures boundary
crossers), run `SessionMerge.resolveOverlaps`, return sessions. Consumers:

- `SyncEngine.pushEligible` — eligibility, start and DURATION come from the
  resolved slice, not the raw row. (The raw row stays the synced truth;
  what we POST is the derived view, same as what the user sees.)
- Timeline UI, `TimeAggregator`, `TimesheetExport` — display/report the same
  seconds we post. `latestEndByTask` may stay raw (recency heuristic only).

Resolution is time-local (a session only interacts with sessions it
overlaps), so windowed resolution is exact — no global pass needed. Cost is
O(n log n) over the window's sessions; windows are day/week-sized.

PREREQUISITE FIX (F23) — IMPLEMENTED 2026-07-07 (same Fable session, ahead
of D1): `resolveOverlaps` now subtracts ALL claimed intervals and keeps
EVERY remaining fragment — the first under the parent's id, later ones under
deterministic child ids from `SessionMerge.fragmentID(parent:index:)` (dual
FNV-1a streams over the parent UUID + "tail-k", version nibble pinned to 8
so derived ids can never collide with random v4 session ids). The old rule
kept only the larger side — a 5-minute manual claim inside a 3-hour auto
session destroyed the shorter remainder from display, aggregation and
(post-D1) posting. Checks updated + a multi-hole determinism/conservation
check added (acceptance criterion 14 below is covered). NOTE for D1/D4:
fragment ids are pure derivations, never persisted — a ledger row written
against a fragment id must be stable under re-derivation, which holds
because (parent, k) is stable for a stable raw set; an EDIT that changes the
claim set can renumber fragments, which is exactly the posted-snapshot drift
the D4 amendment loop detects and amends.

Posting a resolved (possibly trimmed) slice means a LATER-arriving revision
can change the trim after posting. That is not a special case: it is the
same "journal moved after posting" problem as an ordinary edit, and D4's
snapshot-diff amendment loop handles both. To enable it, the ledger row
gains a snapshot of what was actually posted:

```
PostingRecord + postedStart: Date?  postedDuration: TimeInterval?  (additive)
```

## D2. Posting ownership + a synced ledger (fixes F9, F10)

Status 2026-07-08: slice (a)'s ENGINE GATE is BUILT and checked (474/0) —
`SyncEngine.localDeviceID` + `postingOwners`; a non-owner device skips a
backend's entire pass (no post/amend/reconcile/poll; report says
`notOwner`) and sessions stay visibly pending for the owner; missing owner
entry = ownership off (single-device unchanged, pinned). The controller
wires the device id from the sync clock; the owner MAP stays empty until
it becomes a synced setting with (b). Slices (b) synced ledger and (c)
markPushed suppression remain open — they want a fresh design session
around the CloudKit record type.

Two mechanisms, deliberately layered:

**(a) One posting owner per backend connection.** Each registered backend id
gets an owner device (`postingOwner[backendID] = deviceID`, a synced
setting; default = the device that configured the connection; changeable in
Settings). Only the owner runs `pushEligible` and the D4 amendment loop for
that backend. Non-owners track, edit, and read state; they never post.
Credentials already make posting single-homed de facto (Xero tokens are a
per-Mac file, OP keys per-device Keychain) — this rule just makes the
existing reality explicit and closes the OP case where two devices hold
credential COPIES under the SAME derived `OPBackend.stableID`.

**(b) The posting ledger syncs.** `posting_ledger` rows become synced records
(own CloudKit record type, keyed `(sessionID, backendID)`). Merge rule is a
state lattice, not LWW: `posted > skipped/stuck > failed > pending`
(`inflight` sits with `failed`); equal states resolve by newest HLC. Worst
case under any race is a stale duplicate ROW, never a duplicate POST —
because (a) means only one device creates entries. Syncing the ledger is
what makes owner HANDOFF safe (new owner sees full posted history, nothing
re-posts), lets every device's UI show posted state, and gives D3's
reconcile a global truth.

**(c) Kill in-record bookkeeping when sync is on (F10).** With the clock
attached, `markPushed` stops writing `pushedToOP`/`opTimeEntryID` into the
session (no re-stamp, no dirty, no revision minted); the synced ledger row is
the sole carrier. Timeline PATCH/delete reads the entry id from the primary
pm ledger row (and stops hardcoding `OPBackend.stableID` — use the row's own
backendID). The legacy mirror is written only when sync is OFF (community
single-device unchanged); `migrateSingleSlotPostings` already bridges old
data. This removes the bookkeeping-vs-edit LWW conflict at the root instead
of tie-breaking it.

Named counter-argument: owner-per-connection makes posting single-homed — if
the owner Mac sleeps for a week, nothing posts until it wakes, and it adds a
Settings concept. Response: posting is already single-homed by credential
locality; the alternative (claim-based two-phase posting) imports a
distributed-consensus problem — claim expiry, dead-owner takeover, tie-breaks
— into a local-first app with no arbiter, to win a capability (multi-homed
posting) nobody asked for. Surface "posting paused – owner offline since X"
in Settings instead. Revisit only if real users hit it.

## D3. In-flight intent + verify-then-adopt reconcile (fixes F12, F13)

STATUS: the F12 half is IMPLEMENTED (2026-07-07, same Fable session):
`.inflight` PostingState; intent written before every create (no intent ⇒ no
create); a failed `.posted` write now LEAVES the intent row instead of the
old best-effort rollback-delete (strictly safer — no orphan when the delete
itself failed); `reconcileInflight` runs at the head of every backend pass —
verify via `listTimeEntries` (±90 s start/duration match, day-granular when
`hasStart` is false), adopt on match, demote to `.failed` (not `.pending` as
drafted — equivalent eligibility, preserves the attempts counter) on a
confirmed miss, leave `.inflight` when the list itself fails. Settle floor
60 s (`inflightSettleFloor`). Checks: intent-gate + no-rollback-DELETE
(SyncIdempotencyChecks, rewritten from the old delete-pinning check) and
adopt/demote/floor flows (BillingChecks, FakeBackend now records what it
"holds" and lists it back). The F13 resurrection half is ALSO IMPLEMENTED (2026-07-08): `.posted` rows
whose session record was touched after the row's write are verified at the
backend (id-first match); missing entries re-queue and re-post in the same
pass, present ones re-date the row so verification stays touch-bounded.

- Before `createTimeEntry`: write the row as `.inflight` (with
  postedStart/postedDuration filled from the resolved slice). After success:
  `.posted` + entryID. The crash window now leaves evidence instead of
  amnesia.
- Pass start, for each `.inflight` row older than a settle floor (≥60 s —
  Xero's list index lags writes; live-verified 2026-07-06): ask the backend
  whether the entry exists (`listTimeEntries` window matched on taskID +
  start ±1 min + duration ±1 min, or single-entry GET when an id was
  captured). Match → adopt id, `.posted`. No match → back to `.pending`,
  clean retry. Never blind-recreate an `.inflight`.
- The same reconcile covers the resurrection orphan (F13): a `.posted` row
  whose session was tombstone-deleted (entry deleted at the backend) and then
  LWW-resurrected — verify the entry, and on "gone" reset to `.pending` with
  a surfaced note, so the journal and the backend re-converge instead of
  silently disagreeing forever.
- Downgrade note: old builds read unknown states as `.posted` (never-double-
  post direction); a downgrade freezes `.inflight` rows until the next
  upgrade's reconcile clears them. Acceptable.

## D4. Convergence loop replaces edit fan-out (fixes F11, and F8's trim case)

STATUS: FULLY IMPLEMENTED (overnight run, 2026-07-08) — the amendment
half landed after the detection half: update-in-place / delete+recreate
(mustRecreate) / retract-with-reopen / frozen→`.diverged` parked, capped
per pass, unknown-error-safe; 464/0 on the Mac. Original detection notes: every
`.posted` row with a snapshot is compared each pass against the current
resolved contribution — duration/start drift beyond 60 s, and
deleted/fully-covered sessions, are counted per backend
(BackendReport.diverged, AppController.postingDivergences published for the
coming Settings surface) and named in the debug log. Detection never
re-posts and never duplicates. The AMENDMENT half (update/delete/retract at
the backend, entryFrozen → .diverged terminal state) remains to build —
until then the count is the honest "your books have drifted" signal.

Don't wire per-edit-path amendment calls (that is how F11 happened — each new
edit surface must remember every backend class). Instead, `pushEligible`
gains an AMENDMENT phase driven purely by state comparison:

For each ledger row in `.posted` for this backend, compare the row's
snapshot (postedStart/postedDuration + the session's task and comment at
post time — extend the snapshot accordingly) against the CURRENT resolved
session:

- Session deleted/fully-trimmed → `deleteTimeEntry`, row → `.retracted`
  (new terminal state).
- Drifted (duration/start/task/comment) → `updateTimeEntry`; on Xero's
  `movedAcrossProjects` → engine-level delete + recreate, new entryID on the
  row.
- Frozen (`entryFrozen`: invoiced/locked) → row → `.diverged(reason)`,
  surfaced in Settings and the sync report — money-visible, never silent.
- Billability-flip stays prospective-only (unchanged decision: posted
  history is never clawed back BY A FLIP; content edits DO amend).

Because the loop compares state rather than hooking edits, it automatically
covers: local edits, edits synced from other devices, overlap-trim changes
from late-arriving revisions, and reassignments — one mechanism, run by the
posting owner, eventually consistent. Snapshot equality is cheap (a hash
column if profiling ever says so).

## D4b. Invoice-lock layer (Martin, 2026-07-08 — adopted; IMPLEMENTED 2026-07-08)

Status: BUILT and checked (main suite 470/0, Pro 38/0). The seam is
`TaskBackend.invoiceLocks(for:)` (default [:]); the engine polls half-hourly
(`invoicePollInterval`, batch-capped, throttle shared across per-pass engines
via `InvoicePollClock`), stamps `PostingRecord.lockedInvoiceRef`, and the
amendment/verify passes exempt locked rows (drift surfaces on the row naming
the invoice; nothing amends, retracts, or demotes billed time). Unlock is
per-invoice (`SyncEngine.unlockInvoice` / Posting health button) and
suppresses re-lock of the SAME ref (`unlocked_invoices` table); a new ref
locks again. Xero side: Projects API `status` INVOICED/LOCKED decides, one
listTime per project per poll; the invoice NUMBER is not exposed by the
Projects API (verified), so the ref is the constant "Xero" — the fallback
below — until an Accounting API lookup exists.

Martin's proposal, adopted as the POST-INVOICE half of convergence: when a
posted entry is included in a SENT Xero invoice, that fact feeds back and the
underlying session(s) LOCK in Time andeye — shown with the invoice reference,
uneditable through normal gestures. A per-invoice UNLOCK exists for client
queries: unlocking re-opens local editing and re-arms D4 amendment for those
entries (the Xero-side credit-note/void remains the accountant's act; unlock
only lifts the app-side guard).

How it composes with D4:
- PRE-invoice window (post → invoice sent): D4 amendment auto-converges the
  backend to the journal — edits/trims/deletes propagate freely. This is the
  window the lock does NOT cover and amendment MUST.
- POST-invoice: the lock removes the divergence source at the origin (the
  user can't silently edit invoiced time), which is strictly better than
  detecting the divergence after the fact. `entryFrozen` handling remains the
  belt-and-braces for entries invoiced before the lock state arrived.
- Mechanics (Pro side): Xero Projects reports per-entry status
  (INVOICED/LOCKED — already read by getTime for entryFrozen detection);
  poll opportunistically on the sync tick. Whether the INVOICE NUMBER is
  retrievable through the Projects API needs verifying — if not, the
  Accounting API invoice lookup (or "locked by Xero" without a number) is
  the fallback. Lock state lives journal-side (a per-session lock marker +
  invoice ref), synced like other session state.
- Out of scope for the lock (still needs D2/D4): pre-invoice edits,
  multi-device double-posting, entries deleted at the backend, exports sent
  outside Xero, and OP (no invoicing concept — OP entries stay amendable).

## D5. Permanent/transient error classification + no head-of-line stalls (fixes F19)

Connectors classify at the seam: throw `BackendPostError.permanent(reason)`
vs `.transient(underlying)` (Xero already has the typed cases — unknown task,
entryFrozen, rateLimitedDaily is transient-until-tomorrow; OP: 404 task,
422 validation are permanent). Engine policy:

- Permanent → row `.skipped` with the reason surfaced; CONTINUE past it.
- Transient → `break` (today's behaviour: preserve order, don't hammer) but
  with an attempts cap (e.g. 30 passes): at cap, row → `.stuck`, surfaced,
  and the queue CONTINUES past it on later passes.
- The journal summary/report shows counts: posted / skipped-with-reason /
  stuck — so "nothing has posted for 3 weeks" is impossible to miss.

## D6. Finance task mapping: the connector owns translation (fixes F18; IMPLEMENTED 2026-07-08)

Status: BUILT and checked (main 472/0, Pro 38/0), INCLUDING the Settings
editor. `FinanceMappingStore` in Core — lock-protected, with a source-task→
project-key snapshot TABLE the controller refreshes on task-cache changes
(the connector reads from the sync context; a live closure into main-actor
state would race). Design deviation from the sketch below, deliberate:
`FinanceMapping` carries only the finance backend's TASK id — the connector
resolves that task's project from its own cache — so the mapping (and the
Settings editor that writes it) is buildable from the seam's `fetchTasks()`
alone, and backend project ids never leak through the frozen seam.
XeroBackend takes the store optionally and resolves create/update targets
mapping-first (nil store = native-only, pinned). Criterion-10 reopen:
`SyncEngine.reopenMappingSkips` off the store's change handler, which also
persists (finance-mappings.json) and nudges a pass. Settings: "Billing
mappings" section, visible only with a finance backend registered; each
BILLABLE project picks a finance-backend task.

`SyncEngine`/`TaskBackend` contracts stay id-agnostic (no seam change — the
seam is the cross-repo lockstep surface, keep it frozen). A finance connector
receives at registration a mapping store (Core-owned, Settings-edited):
project-level `sourceProjectKey → (xeroProjectID, defaultXeroTaskID)`. The
connector translates internally; an UNMAPPED task throws
`BackendPostError.permanent("no Xero mapping for <project>")` → `.skipped`
with reason via D5 — a visible prompt to map, never a stalled queue, never a
`.failed` retry storm. Registering Xero on the seam MUST NOT ship before D5 +
this gate exist (a single billable OP session would otherwise stall the Xero
queue permanently).

## D7. Billing rules divergence (bounds F14)

v1 keeps `billing.json` per-device but makes it harmless: the ownership rule
(D2a) means exactly ONE device evaluates `financeEligible` for a given
finance backend — divergent copies on other devices cannot cause divergent
POSTING. Fold billing rules into synced settings when settings-sync lands;
until then, document that billable flags should be set on the posting owner.

## Sequencing

- WITH the CloudKit transport GA (blockers): D1, D2 (all three parts).
- BEFORE Xero registers on the seam (blockers): D5, D6, plus future
  licensing work (F16), out of scope here.
- BEFORE "seamless Xero" is marketed: D3, D4.
- Later: D7's synced rules; F17's tick-side drift clamp (one-line hardening
  in `HLCClock.tick`: cap `physicalNow` absorption symmetrically).

## Acceptance criteria (andeyeTTChecks, Mac-runnable)

1. Two replicas, overlapping auto+manual slices: both derive the identical
   resolved view; the pusher posts exactly the trimmed durations; aggregate
   seconds equal posted seconds.
2. Two replicas, same backend id, both hold eligible sessions: only the
   owner's engine posts; after full sync both ledgers agree; total external
   creates == session count (mock backend counts creates).
3. Owner handoff: flip owner between passes; nothing re-posts; the new owner
   amends/creates correctly using the synced ledger.
4. Ledger merge lattice: `(posted, pending)`→posted, `(skipped, failed)`→
   skipped, `(posted, posted-different-entryID)`→newest-HLC, order-
   independent (property-style over shuffled application orders).
5. With sync on, `markPushed`-equivalent bookkeeping mints NO new revision:
   an edit raced against a post loses neither the edit nor the posted state.
6. Crash-window sim: `.inflight` row + entry existing at the backend →
   reconcile adopts (no second create); `.inflight` + no entry → clean
   retry, exactly one entry after.
7. Resurrection: post → tombstone (entry deleted) → resurrect via newer
   edit → reconcile detects the missing entry and re-posts exactly once.
8. Amendment loop: posted session then trimmed/reassigned/deleted →
   update / delete+recreate / retract respectively; `entryFrozen` →
   `.diverged` surfaced, not retried, not silent.
9. Head-of-line: queue [permanent-fail, ok, ok] → one `.skipped` with
   reason, two posts, SAME pass. Transient at cap → `.stuck`, queue drains
   past it next pass.
10. Unmapped finance task → `.skipped("no Xero mapping…")`, queue proceeds;
    mapping added → session posts on the next pass (skipped rows for THIS
    reason re-open, unlike other skips — model as `.skipped` reason-code the
    engine re-tests, or clear-on-mapping-change). NOTE 2026-07-08: the reopen
    ships WITH the D6 mapping store — its change-handler is the only sane
    trigger; a generic reason-code re-test has no change signal to key on.
    The skip half is live (PermanentPostError path, checked).
    DONE 2026-07-08: D6 landed — `reopenMappingSkips` off the store's
    change handler, clear-on-mapping-change, exact-reason match; checked
    both directions (its project reopens+posts, other skips stay closed).
11. Downgrade safety: rows in the new states read as `.posted` by a decoder
    limited to the old enum (never-double-post direction preserved).
12. Anti-entropy (D0.1): replicas A and B concurrently edit S; B's stale
    push lands AFTER A's newer one (simulate `.allKeys` overwrite in the
    mock server); after each replica completes ONE further sync cycle, both
    replicas AND the server hold A's revision. (This check fails against
    today's syncer — it pins the F21 fix.)
13. Backlog enable (D0.2): enabling sync with >400 dirty revisions pushes
    the entire backlog in chunks; a mid-backlog batch failure leaves the
    failed chunk (and only it) dirty for retry.
14. Middle-split determinism (F23): the 5-min-inside-3-h case yields BOTH
    remainder slices, with identical child ids on every replica, and total
    derived seconds == raw seconds minus the claimed overlap.

The counter-argument, named: this is a lot of machinery for a pre-alpha with
zero multi-device users. Response: half of it (D5, D6, F16) is needed for the
FIRST Xero customer regardless of device count; the other half (D1–D4) is
exactly the set that cannot be retrofitted after CloudKit sync ships without
a data-repair migration across customers' journals and their real books —
the same "do it at the last clean moment" logic as future licensing work
(F16), out of scope here, and that moment is now.

# TODO

## Martin's 13 Aug replies — decided build programme (pre-approved, no
## further asks; full Q&A in brain2 Time&I-Q&A-archive, 2026-08-13 section)

- [ ] #1 PRIORITY — correction ledger + teach-scope fix (replies 9 + 15).
  Mis-attribution from over-learned corrections is hurting him daily (an
  Obsidian "Ambi4-fromMartin" window tracked as andeye insurance 87% off a
  past correction). DIAGNOSED 2026-08-13 — full teach-path inventory, the
  three real over-learn mechanisms (feature generalisation with no
  specificity discount; per-session flit dominance inside multi-session
  blocks; bulk review assign teaching every surface), the forget-doesn't-
  refile root cause, and a 6-part minimal fix set with file:line targets:
  docs/superpowers/specs/2026-08-13-correction-overlearning-diagnosis.md.
  BUILD next (fix set first — it stops the bleeding — then the ledger):
  (a) journal every teach — gesture, surface, features written, weight,
  timestamp, originating slice (the spec's inventory table is the exact
  write-point list to instrument); (b) surface it — the evidence card
  names the exact correction that produced a learned association ("taught
  2 Aug when you reassigned X on surface Y"), and a ledger view lists
  corrections with everything each has since decided; (c) teach scope =
  spec fixes 1+2 (duration-gated/weighted teaches, IDF-style specificity
  weighting); (d) forget must re-attribute = spec fixes 3+4 (+5 surface-
  key normalisation, 6 symmetric discount — 6 surfaced to Martin when
  built, it's flagged an owner call in the attribution-learning spec);
  (e) cut the user-visible pause before tracking follows a tab change.
  PROGRESS 2026-08-13: fixes 2/5/6 LANDED (specificity blend, surface-key
  normalisation + primed.json migration, prime-displacement discount —
  CHANGELOG this date; fix 6 flagged in fromClaude). Fixes 1 (TeachScope
  duration-gated/weighted bulk teaches) and 4 (card never mixes slice
  certainty with span provenance) LANDED later same day. Fix 3 (forgettable
  targets the RECORDED provenance; slice re-derives via the existing
  post-forget refile pass) LANDED same day — the whole 6-part fix set is
  now in. Ledger (a)+(b) LANDED same day (CorrectionLedger + card
  naming + Corrections segment — CHANGELOG). Latency (e) LANDED
  2026-08-13 (event-driven early poll — CHANGELOG; needs Martin's
  on-device feel, no off-device check possible). The reverse index LANDED
  2026-08-13 (CorrectionImpact, computed at view time — exact for
  prime-decided slices, honestly-flagged same-app pull for ranked ones;
  no schema change needed — CHANGELOG). The #1-priority programme is now
  fully built; what remains everywhere is Martin's on-device feel.
- [x] Reassign scope display (reply 3 = y) — DONE 2026-08-13, both halves
  (CHANGELOG): relabel banks pre-stretch time as it stood and moves only
  the current tab/window's contiguous stretch; popover Reassign label
  shows "moves 1m on this tab · 10m total" when the figures differ.
  Martin tests for a few days (the 2026-07-17 item below stays open as
  the feel gate).
- [x] Away rescue = MORE AUTO (reply 2): the rescue flow SHIPPED
  2026-08-13 (AwayRescue planner + Settings ▸ Away rescue preview/apply —
  CHANGELOG; snapshot-verified). His end-time extension LANDED
  later same day (orphan-mode planner + applyTimelineEdit hook —
  CHANGELOG). The older away item's Mac-half span filters landed
  2026-08-14 (below) — the whole away programme is now built.
- [x] Double-forget escalation (reply 4) — DONE 2026-08-13 (CHANGELOG):
  second forget on the same card unlocks "delete ALL learned experience
  for <task>" (counts + totals + primes toward it; pins/stickies/rules
  stay; one ⌘Z; ledger-journalled). Single-forget behaviour unchanged.
- [x] Correction-propagation UI (reply 8) — v1 SHIPPED 2026-08-13
  (CHANGELOG): correction gestures offer same-target contradictions on
  the timeline (dim + dashed candidates, click-toggle, one approve as
  the user's word). Both v1 cuts CLOSED 2026-08-14 (CHANGELOG):
  click-DRAG sweeps candidates (painted to one value, fixed by the
  first candidate touched), and entering the pass auto-widens the
  visible window back to the first affected entry (right edge pinned).
  His reply-8 spec is now fully built; feel rides his next real
  correction.
- [ ] Settings restructure (reply 10): PARTLY DONE 2026-08-13 — Billing
  section landed (currency + Billable items list, label squish and
  garbled caption fixed, snapshot-verified; CHANGELOG). CLOSED 2026-08-13: the
  mis-filed notice now also shows in Review, and the timeline marks each
  suspect posted entry with an orange outline + ⚠ and a tooltip naming
  where today's rules would file it (CHANGELOG). The "Donut section"
  turned out to be a feel-test wording error — no such section was ever
  built; donut controls live under Behaviour ("Donut button opens") and
  the Time Donut legend itself; nothing to gather.
- [x] Monochrome menu bar redundancy (reply 11) — DONE 2026-08-13: NOT
  redundant (same-colour = one fixed colour of your choosing; Monochrome =
  macOS template tint matching the system's own icons, adapts light/dark),
  but the two no-colour affordances sat far apart and read as duplicates.
  Monochrome now sits directly under the colour pickers with a caption
  contrasting the two; manual (site + MANUAL.md) synced. Suite 933/0 on
  the bridge.
- [ ] Billable visibility + redo (reply 12): badge half DONE 2026-08-13
  (currency mark on billable timeline slices; "billable" capsule on donut
  legend task rows incl. inherited — CHANGELOG; landed in be829e4, TODO
  note followed one commit late). REMAINING: ⌘⇧Z REDO (raises the
  existing undo-stack item from planned to user-hurting); the undo/redo
  notice must never hide behind the Time&I popover.
- [x] Agent UI visibility (reply 10) — DONE 2026-08-13: timeandeyeSnapshots
  + SnapshotHarness render every Settings pane, popover, Review and rules
  ledger to PNG over the bridge (NSHostingView offscreen — ImageRenderer
  placeholder-glyphs AppKit-backed containers); run
  `bash .vibe/mac-test.sh run timeandeyeSnapshots /tmp/andeye-snaps` then
  scp the PNGs back and Read them. First use verified + fixed the Billing
  pane visually (CHANGELOG).
- [x] Feel-test instruction rule (replies 14/16): every feel-test ships
  step-by-step click paths — adopted 2026-08-13, fromClaude items 1-2
  rewritten to it.

## Post-flip (2026-07-17)

- [ ] Reassign scope (Martin's call, 2026-07-17; BUILT 2026-08-13 with the
  display half — this item now tracks only his few-days feel test): a
  Reassign click relabels ONLY the current tab/window's span — the
  assumption is the user was happy with tracking until they switched; no ⌥
  whole-session sweep for now (could extend later if the reassign clearly
  informs prior spans, parked as annoyance-risk). The visible tracked-time
  decrease is the user's alert. Martin tests for a few days once built.
- [ ] Popover mode default (Martin's call, 2026-07-17): keep the snap-back to
  the default after each action — vary-per-click, no master toggle. Clicking
  the "Reassign/Switch to" label should ALSO vary from the default for that
  click (currently clicking the current task is the only discoverable
  vary-path). Candidate: right-click on it to change the default action.
  (Related decision closed: the 60 s switch hold stays, not a setting.)
- [ ] Delete Projects/timeandeye-preflip (Martin, ~week of 2026-07-20) — the
  last unrewritten pre-flip copy; everything private in it is preserved in
  andeyePro. FILED in OpenProject 2026-08-12 (checkbox on WP 223) per the
  2026-07-17 note; the folder deletion itself remains Martin's.

- [x] Fix CI on the fresh public repo — DONE 2026-07-17: first Actions run
  failed to COMPILE timeandeyeMac (runner Xcode drifted ahead while CI was
  frozen; not the suspected Checks fixture data — the djb2 collision fixture
  premise re-verified intact, hues 173/174). Seven `guard let self` hoists out
  of nested `Task { @MainActor }` blocks, one explicit-CGFloat bind in
  AndeyeLogoImage, one type-check-ceiling break-up + one `try?` warning in
  AppController. See CHANGELOG 2026-07-17.

## Review-fix cluster (2026-07-11)

- [x] Undo ordering + group reentrancy + reconcile delete tracking
  (F3-3/F3-4/F3-7) — DONE 2026-07-11: `undo()` chained its inverses (were
  detached, unordered Tasks that interleaved on rapid ⌘Z⌘Z) so N completes
  before N+1, still off the caller. `UndoStack.group` gained a task-local group
  token: a registration folds in only when it runs in the group's OWN call
  context, so a stray registration interleaving during a group body's await is
  its own ⌘Z step, not swallowed under the group's label (new interleave
  check). `applyReconcile` now tracks which backend deletes actually succeeded
  (was `try?`-swallowed) — undo recreates only those, and a failed delete
  surfaces via `lastError` instead of undo manufacturing a duplicate. Suite
  864/0.
- [x] Window activation + green button + re-front (F1-1/F1-5/F1-2/F1-4) — DONE
  2026-07-11: Time windows now carry their SCENE id ("time"/"time2") as window
  identity (was the shared VIEW mode), so activation fronts the right one and
  the open grant is a plain identity match (no "time"↔"time2" cross-grant that
  killed the sibling's green button for 4 s); the view mode stays in the title
  for the scroll-pan monitor. `GreenButtonHelper.greenClicked` holds off while a
  fullscreen enter/exit animates (shared `isMidFullscreenTransition`), matching
  the timer path. The 1 Hz off-Space re-front backs off (a few tries per
  episode, then once per 10 s) and logs only on state change. DebugLog gained an
  8 MB cap (atomic rename to `.old`). AppKit paths aren't check-covered (checks
  don't link timeandeyeUI); verified by suite 863/0 + release build.
- [x] Mechanical polish cluster (strings, search index, small UI correctness)
  — DONE 2026-07-11: SettingsIA titles/keywords brought current (Donut button,
  Hide banners, walk-figure lock label; "donut" keyword added to the two Time
  Donut legend links); TimelineView Move-bar gate switched off the deleted
  `reviewThreshold` to `certaintyAutoPushThreshold`; Local tasks project field
  binding no longer forces "Personal" into the text (raw optional now, prompt
  restored); email-order caption only claims the fixed ladder when the stored
  order actually matches it; iOS/menu-bar "pie"→"donut" wording fixes; eight
  stale "Change to" comments renamed to "Reassign". Suite 862/0.
- [x] Sync requarantine double-post race — DONE 2026-07-11: `requarantine`
  read the posting record then wrote the stale `.stuck` snapshot in a separate
  store call; the retry-stuck-kicked async pass (off the main actor) could
  write `.inflight` in the gap, get clobbered, and later re-post (duplicate).
  New atomic `JournalStore.setPostingRecord(_:unlessState:)` does check+write
  in one critical section (SQLite holds its lock across both); requarantine
  uses it. A create already on the wire stays truthful (reconcile owns it);
  undo is a no-op for that row. New ResolvedPosting check.
- [x] Billing mark undo window — DONE 2026-07-11: `setSessionBillable` awaited
  `syncIfEnabled()` inside the gesture, so an entry mark (which bypasses the
  `since` gate) posted before ⌘Z could fire — a mis-click stuck on the books,
  undo window structurally zero. Debounced the sync kick (and the undo's) so an
  immediate undo retracts the override before the post; widen-to-task/project
  covered via the same method. A mark that has already synced still never claws
  back (design fact kept). New BillingChecks case.
- [x] Refile backend hygiene + certainty — DONE 2026-07-11: `applyRefiles`
  re-pointed a posted slice's task with no backend hygiene, leaving its entry
  filed under the old work package (money mis-filed). Now sheds the linkage
  (delete old entry, clear id/flag, deferred re-post under the new task) via
  the same path `applyTimelineEdit` uses; undo re-posts under the restored
  task. Also fixed refile certainty inheriting the old task's confidence
  (`max` → re-derived `finding.score`). Decision factored to Core
  (`ContradictionRefile.apply`); `RetroDigest.PriorSessionState` gained
  `priorPushedToOP`; 3 new checks.
- [x] Housekeeping ahead of the public flip — DONE 2026-07-11.

## Tracking fixes (2026-07-11 log cluster)

- [x] Pending-switch revert gate — DONE 2026-07-11: an ungated revert let a
  faint boost-only sighting of the base task (running-clock lift to ~0.42 on
  an ambiguous surface) cancel a 0.95-confident pending switch (Martin's
  14:22:30–32 log). The revert now requires the same `uncertainBelow` (0.6)
  floor a forward switch needs; a genuinely confident return still reverts.
  `SessionTracker` check reproduces the sequence both ways.
- [x] Reassign taught twice — DONE 2026-07-11: `relabelCurrentSession` also
  called `attributor.confirm` (weight 2) on top of the controller's
  deliberate `attributor.assign`, double-counting every correction. Dropped
  the tracker-level teach (its only production caller is
  `AppController.changeCurrentTask`, which owns the single `assign`); the
  reassign now teaches exactly once.
- [x] Evidence Card window duration — DONE 2026-07-11: the timeline card
  carried only the window's start; it now carries the span end too and shows
  a quiet start–end · duration caption under the window name (omitted on the
  popover's live card, which has no recorded span).
- [x] Adjacency boost label honesty — DONE 2026-07-11: the reasoning read
  "+22%" for a value that is percentage POINTS (0.19 → 0.42); it now reads
  "0.19 → 0.42 (+23 pts)". Drawer + live share the one `apply` format.
- [x] Live decay was dead (F2-2) — DONE 2026-07-11: `handleFocus`'s
  `handleInput(now)` bumped `lastInput` to `now` before `attribute()` read
  `liveContinuity`, so the running-clock boost never decayed — full strength
  regardless of inactivity. `handleFocus` now captures the previous input and
  passes it via `liveContinuity(at:lastActive:)`. New integration check drives
  `SessionTracker` end-to-end (synthetic-Continuity checks were blind to it).
- [x] Undo re-stamps provenance (F2-3) — DONE 2026-07-11: undo of a task-change
  timeline edit re-ran `applyTimelineEdit`, which re-stamps `.userAssigned` on
  a task change, clobbering the row's original provenance. The inverse now puts
  the pre-edit provenance back (mirrors `reassignTimelineSessions`' undo).
- [x] Leisure inherits work provenance (F2-4) — DONE 2026-07-11: the
  non-work→leisure flip in `commitSwitch` never updated `currentDecision`, so
  leisure spans carried the prior work task's provenance (incl. `userAssigned`).
  Now stamps an honest engine decision (`.ranked`) for the leisure target.

## Review drawer (Martin's critique, 2026-07-10)

- [x] Walk-through confirm (his respec) — DONE 2026-07-11: whole-day
  confirm rejected for partial-day reality; built his respec verbatim —
  arrow the day's slices left↔right (⌘[/⌘], bare arrows with list focus),
  dig in at will, every visited slice marked viewed, ONE **Confirm viewed**
  takes the engine's current read of exactly the viewed slices as the
  user's word (sessions stamped `userAssigned`/"confirmed in review", full
  certainty, one ⌘Z). Decisions taken: viewed state is controller-held
  in-memory (survives window close/reopen, resets on app relaunch —
  attention is never journalled); scrolling/Expand-all never mark viewed
  (rendering ≠ looking); a nothing-matched slice stays queued even when
  viewed (no read on show to confirm). `ReviewWalk`/`ReviewConfirm`
  Core-checked (20 checks).

- [x] Martin's third pass — DONE 2026-07-10: the click-to-toggle model
  (below) was "unconventional and unintuitive", the selection blue "darker
  and harder to discern", the twisty "much harder to successfully click".
  Selection is now the macOS default (`ReviewSelection` value type: click
  replaces, ⌘-click toggles, ⇧-click spans from the last non-shift click
  over the flattened visible rows — NSTableView anchor rules), the
  highlight is the solid native accent fill with white text, and both
  twisties have 20×18pt targets outside the selection click surface.
  `ReviewRangeSelect` absorbed and deleted.
- [x] Martin's live drawer feedback, second pass — DONE 2026-07-10:
  (1) expand-all was "intolerably slow" — per-slice ±30-day journal query
  + full ranker explain ran synchronously in EVERY render pass for every
  open disclosure; now structure opens instantly and the expensive detail
  is lazy, batched (one range query per batch via `SliceNeighbours.batch`)
  and cached (`AppController.sliceDetails`). (2) The per-slice **Assign…**
  button (shipped that morning) is replaced by unified click-to-select
  (`ReviewSelection`): click a slice to toggle its highlight, header/left
  margin toggles the group, shift-click sweeps stacks; the assign bar and
  its certainties cover the whole mixed selection.
- [x] Martin: naming call on the assign bar's **Do not track** button —
  DONE 2026-07-10, his call: **[Clear]** ("drop from this list and don't
  add to timesheets … may be selected because the user can't be bothered
  assigning 1m tracks - which the app should not 'learn' from"). Clear
  (and ⌫/⌘D) still marks rows decided, stays ⌘Z-undoable and leaves the
  journal/timeline untouched — but no longer teaches
  (`Target.teachesAttributor` is now false for `.doNotTrack`): no sticky,
  no learned don't-track lean, no future clock-stop from a clear. Learned
  associations from past clears stay in the store untouched. The
  timeline's "Don't track this" keeps its deliberate teach (direct
  `attributor.assign`, not gated by the flag).
- [x] Adjacency boost beyond the drawer (DONE 2026-07-10): Martin made the
  call himself (his — "the running timer IS a sound prior without
  outcome data"): the live prior shipped without waiting for constant
  fitting. `AdjacencyBoost.live` (same constants/maths as the drawer's
  one-sided neighbour) feeds `Attributor.attribute`'s ranked fallback via
  `SessionTracker.liveContinuity` — the COMMITTED slice's task, decaying
  over the input gap; definitive sources (pin/sticky/URL/rule) return
  before it; stopped clocks carry no prior. Every applied boost DebugLogs
  ("live-adjacency …") for the fitting pass, which stays open below.
- [ ] Adjacency constant fitting: pair the logged live/drawer boosts with
  the correction or confirmation that followed and fit the
  bothSides/oneSide/decay constants from outcomes (both feeds share them).

## Undo — remaining non-undoables (audit, 2026-07-09)

The infinite-undo audit (CHANGELOG 2026-07-09) closed every local
registration gap; these stayed open deliberately — each needs a design
call, not a mechanical fix:

- [x] Duplicate reconcile (`applyReconcile`) has no undo: the duplicate
  backend entries are DELETED remotely, so a local restore would re-point
  sessions at dead entry ids (worse than no undo — later edits would PATCH
  a 404). DONE 2026-07-10 via the reconcile-journal route:
  `ReconcileUndoPlan` snapshots the doomed entries whole BEFORE the apply;
  ⌘Z re-creates them at the backend (fresh ids), restores the survivor's
  pre-merge comment, and re-points each slice at its own entry's fresh id
  — never at a dead one.
- [x] `unlockInvoice` / `retryStuck` have no undo (re-lock / re-quarantine).
  DONE 2026-07-10 — decision: repair gestures are still data edits, so they
  join the app-wide ⌘Z stack. Unlock returns a row snapshot and ⌘Z re-locks
  (restores refs + the diverged park, forgets the sticky suppress; skips
  rows whose entry id moved on). Retry returns the cleared rows and ⌘Z
  re-quarantines (never over a `.posted` or `.inflight` row — no orphaned
  or double-posted entries).
- [x] Live pick (`userPicked`) and Stop join the ⌘Z stack — DONE
  2026-08-13 with (a) ⌘⇧Z REDO (UndoStack redo stack, NSUndoManager-style
  routing — spec docs/superpowers/specs/2026-08-13-undo-redo-core.md) and
  (b) undo TRANSPARENCY (every ⌘Z/⌘⇧Z banner names what it changed, and
  the banner now floats above the popover). Money already posted is
  still never clawed back silently. All five conversion batches are now
  in (3-4 on 2026-08-13, 5 — review assign / timeline edit / timeline
  reassign — on 2026-08-14; audit trail in the spec). Deliberate
  boundaries that remain: `replaceSession` (fresh piece ids) and whole
  undo-GROUP entries — honest ⌘⇧Z stops, never silently skipped.
- [x] `ingestAIResponse` applies N assignments as N undo steps (each fully
  undoable); grouping into one step means making the call async (UI ripple).
  DONE 2026-07-10 without the ripple: `UndoStack.groupSync` — a
  synchronous grouping flavour — bundles the batch into ONE ⌘Z step from
  inside the existing sync call; no UI signature changed.
- [ ] A comment undone AFTER its slice flushed only clears the in-flight
  copy; the flushed row keeps it (editable in the timeline). A posted
  task-feed comment is never retracted — undo must not rewrite a backend's
  history silently.

## Time-window polish (Martin, 2026-06-27)

- [x] Window titles (DONE 2026-06-28): the Time window is titled "Timeline" when showing the
  timeline and "Time Pie" when showing the pie.
- [x] Pie view — closeable highlight-calendar (DONE 2026-06-28). Anchorable
  `TimePeriod` in Core (unit-checked); a `MonthCalendar` grid bottom-right (below
  the key) highlights the shown range and re-anchors on a tapped day; the period
  picker moved below the calendar. "This week" → tapped day's whole week;
  "Last 7 days" → 7 days ending on today's weekday; future days disabled.
- [x] Pie view — OpenProject-only + total moved bottom-left (DONE 2026-06-28).
- [x] Reconcile "open in OpenProject" opened the bare work package — DONE
  2026-07-09: reconcile now lands on the global cost report pre-filtered to
  the WP (`/cost_reports?fields[]=WorkPackageId&...&set_filter=1`), the same
  link OP's own "spent time" field builds (verified in opf/openproject
  source; grammar stable since at least v12). New TaskBackend seam method
  `taskTimeEntriesURL` (default nil → falls back to the task page); the
  popover right-click keeps the task page.

## Optimisation backlog (programme review, consolidated 2026-06-26/27)

A Programme-Manager + per-domain Project-Manager pass, then an adversarial
deep-review, produced a 9-pass plan (CHANGELOG 2026-06-26/27 for what's landed).
DONE so far: store index + bounded query, TimelineView sessions cache,
cross-midnight controller fixes incl. the live-start pair (rank 1), attribution
floor/startsWith/tiebreak (rank 4), scroll-monitor hardening (rank 5),
formatter/dominant-span dedupe, KeychainStore→APIKeyStore. Remaining ranks:

- [x] Rank 2 — crash-safety (DONE 2026-06-27): a task switch never clears/rewrites the 60s
  checkpoint, so a hard crash can double-recover time already journalled
  (duplicate time + duplicate OP entry). Clear-then-rewrite the checkpoint on
  switch; extract a Core `CheckpointRecovery` (reject promotion when the stale
  span is already covered); tighten the checkpoint timer to ~12s while tracking
  (Martin: OK if no perf/energy hit — use a generous Timer tolerance so the OS
  coalesces the wakeup). Attach the superseded-survivors here: `session(id:)`
  single-row fetch + COUNT-based `updateJournalSummary` (stop decoding the whole
  table on every mutation).
- [x] Rank 3 — OP write path (DONE 2026-06-27): double-create closed AND the journal-driven duplicate-reconcile tool shipped (richest-survivor, confirm-each, Settings ▸ Maintenance).
  Original spec: `SyncEngine` marks pushed AFTER the POST, so a
  throw after a successful create re-POSTs next sync (likely root of the ~143
  surplus entries). Make create idempotent across a failed mark (delete the
  orphan on the failure path); surface a malformed created-entry id instead of
  swallowing it. Then the journal-driven duplicate reconcile — DECIDED policy
  (Martin): never two records for one point in time; keep the RICHEST record
  (most likely the real one), fold the deleted record's data into the survivor
  as a comment (nothing irrecoverable), re-point the journal's opTimeEntryID to
  the survivor, confirm-EACH (no bulk auto-delete), never delete an OP entry
  with no exact journal match. Land before the backend seam.
- [x] Rank 6 — banked menu-clock under-count (DONE 2026-06-27): brief excursions re-tagged back to
  the base task aren't recovered by `bankedElapsed + running`; compute the
  tracking clock from `tracker.liveSliceStart` so it equals what posts to OP
  (CHANGELOG 2026-06-24 follow-up). Optional: gate the 1Hz title rebuild to
  first-minute/minute-boundary (keep the 1Hz timer for scheduledStop).
- [x] Rank 7 — test backfill (DONE 2026-06-27) (pure test code): SessionTracker live-editing
  (commitLive/relabel/backdate/adjustCurrentStart/reevaluate/liveSliceStart) +
  away-mode; parser aliases/negations; PinScope malformed-URL fallthrough.
- [x] Rank 8 — dead code (DONE 2026-06-27): delete `WorkspaceLayout.swift` (228 dormant lines,
  recover from git when re-added) + remove the dormant `taskLayouts`/`lastLayout`
  settings in the same commit; one-line comment that the pins.json migration is
  a self-terminating one-shot. (One owner for the Core window-helper extraction
  — rides this or rank 7, not duplicated.)
- [x] Rank 9 — backend seam CORE DONE 2026-07-01 (branch fable2): `TaskBackend`
  protocol + `BackendPageRecognizer` in Core; OP behind `OPBackend` (owns the
  typed-422 fallback, which now persists across syncs); `SyncEngine` and
  `AppController` backend-agnostic; Attributor recognizer hook done; standalone
  = nil backend (no SyncEngine exists → can't silently mark-push into a void).
  `RemoteEntryID`/`TimeActivity`/`RemoteTimeEntry` typealiases mark the Xero
  widening points (entry ids → String GUIDs). TimesheetExport (CSV/Markdown +
  Settings ▸ Maintenance copy buttons) DONE 2026-07-01. REMAINING sub-slices:
  task_comments table (standalone comment storage), open-in-backend
  right-click (taskWebURL helper exists), project-slug matching. Plugin loader
  stays deferred; Xero adapter = one `TaskBackend` conformer + settings pane.

## New-batch features (Martin, 2026-06-27)

- [ ] #1 follow-on — weight controls SHIPPED 2026-06-28 (boost/always on the why
  panel); STILL OPEN: use the explain
  data to chase the live mis-attribution bugs (tracking as the andeyeTT task while on
  Chrome; the revert button offering a stale task — `revertTargetTask` returns
  `previousTask`, which can be wrong; now diagnosable via the explain panel).
- [x] #5 — combined Timeline/Pie view: DONE (CHANGELOG 2026-06-27). Now ONE Time
  window, views flipped in place by clicking a preview; ⌃/right-click a preview
  opens the other view in a 2nd window. Footer launcher is a live today mini-pie;
  3-way open Setting; last-viewed persists. User manual written (MANUAL.md).
  Possible polish: richer mini-pie (task rings); only-one-monitor if two timeline
  windows are open at once (currently two timelines would double-pan - uncommon).

## Review findings parked for an on-device session (fable2 review, 2026-07-01)

These need live verification (UI feel / sensor timing), so they were reviewed
and recorded rather than fixed blind:

- [x] Sensor poll runs the Chrome-tab AppleScript + AX title read synchronously
  on the main actor every 2 s (Sensors.swift poll). Same hazard class as the
  2026-06-30 email-capture freeze, just lower probability (a hung/modal Chrome
  stalls tracking AND the UI). FIXED 2026-08-14 (CHANGELOG): `TabURLEngine`
  moves the URL read to an off-main osascript subprocess behind a
  browser+title cache (poll answers instantly, corrected-URL re-poll on
  arrival), and every AX read carries a 1 s messaging timeout. The
  on-device soak this item asked for still stands — it rides Martin's
  next few days of real use alongside the 13 Aug latency feel-test.
- [x] `fullPickList()`/`searchTasks()` re-ran per SwiftUI render — DONE
  2026-07-09: memoised in AppController (one cache serves all 6 call sites),
  invalidated by taskCache/settings/connectedAs didSet + persistAssociations
  (every learning write), 5 s TTL backstop for the ranking's time-decay term;
  searchTasks memoises the last (query, base) pair for keystroke renders.
  TaskPickerBar consolidation of the 4 filter-bar implementations still open
  as a separate refactor if wanted.
- [x] Two open timeline windows cross-pan — DONE 2026-07-09: HostWindowAccessor
  resolves the view's actual NSWindow; the scroll monitor gates on the
  INSTANCE (identifier check kept only as the pre-resolution fallback).
- [x] Spent pie selection is positional (`project(i)`/`task(i,j)`) into a
  re-sorted `nodes` array — a background reload while a wedge is pinned can
  silently retarget the pin to whichever task now sits at that index. Key the
  selection by TaskRef/label instead. (DONE 2026-07-02 — PieGeometry in Core,
  label-keyed Selection + resolve(), checked. On-device: confirm hover/pin
  feel unchanged.)
- [ ] AppController (1,9xx lines) hides three extractable units: the timeline/
  journal editing block (~575 lines, no AppKit — could move toward Core as a
  TimelineEditor), sync orchestration (~100 lines, `SyncCoordinator`), and the
  pure `UndoStack`. Mechanical, but big diffs — do when the file next fights
  back. (UndoStack DONE 2026-07-02 — Core class + 5 checks; the other two
  remain parked.)

## Open

- [x] `timeandeyePhone` now runs in the in-container Linux checks subset:
  `PhoneController`'s Combine use is `#if canImport(Combine)`-gated with an
  internal shim for `ObservableObject`/`@Published` on non-Apple platforms
  (see CHANGELOG 2026-08-07). `PhoneController` still stays Mac/iOS-real on
  Apple platforms – the shim file compiles out entirely there. Remaining
  Mac-only suites (`Mac`/`Theme`/`EmailCapture`/`AndeyeLogo`/`AndeyeTheme`/
  `FullscreenPose`/`JournalStore[SQLite]`/`MenuTitle`/`SupportDir`/
  `License`/`ResolvedPosting`/`PostingMachine`/`MultiDevicePosting`) import
  `timeandeyeMac`/`timeandeyeTheme`/CryptoKit directly and have no portable
  path. (this commit)

- [ ] STANDING PRACTICE (every session, not a one-off): any time you
  trigger a GitHub CI run (any push to main fires checks.yml), set a
  ~15-minute background timer and then check the run's conclusion via
  the Actions API; report a failure to Martin unprompted (re-check at
  ~30 min if still running). Never push-and-forget — the 17–23 Jul
  red-main streak went unnoticed because nobody looked.

- [x] CI checks suite RED on main — DIAGNOSED + FIXED 2026-07-23: the 17 Jul
  runs died compiling (cured by ba37fae + ecea026); the 23 Jul run built and
  RAN the suite on macos-14, and its red is
  one deterministic check failure, `[Predicate] email fields` — its fixture's
  second correspondent `martin@example.com` contains the check's own
  `example.com` negative probe (self-contradictory since birth, 1f8e215).
  Correspondent 2 is now `sam@northgate.example`. CONFIRMED green
  2026-07-24: run 30114753472 on 7ce0448, TOTAL 909 passed, 0 failed. Log route that works in-container:
  run-level zip `gh api .../actions/runs/<id>/logs` (redirects via
  results-receiver.actions.githubusercontent.com, reachable) — job-level
  log endpoints redirect to firewalled Azure blob storage. See CHANGELOG.
  Residual oddity, not chased: pre-flip local "0 failed" totals (07-08 →
  07-13) can't have executed this check as recorded; treat historical
  suite-count claims from container sessions as unverified.

- [x] Away mode ("I'm leaving my desk", ⌘⇧L) must keep RECORDING window/
  focus evidence while pinned. Intended use is off-computer work on the
  pinned task for potentially 8h+ (client days), so NO duration cap.
  Today `SessionTracker.handle` discards all events while `away` is set,
  so an away stretch leaves zero journal evidence — if you forget to
  toggle off, the at-computer work after returning is unreconstructable
  (bit Martin for ~24h, 2026-08-07). Requirements: (a) attribution stays
  pinned exactly as now — recording must not disturb the pinned session;
  (b) focus/window/input events still land in the journal, marked as
  observed-while-away; (c) a recovery flow (Settings) that replays the
  recorded evidence over a chosen away stretch so the user can rebuild
  and re-attribute what they actually did at the computer after
  returning. Design open: does recovery re-run the attribution engine
  over the recorded events, or just present the raw window timeline for
  manual splitting? Cause (code-read 2026-07-23): SensorHub polls
  frontmost app + focused-window AXTitle + tab URL every 2 s
  (Sources/timeandeyeMac/Sensors.swift poll()/focusedWindowTitle);
  Electron keeps renderer accessibility OFF until an AT opts in, and the
  window chrome title doesn't change per chat — so the surface key never
  changes. Fix sketch: set AXManualAccessibility on the app element (the
  EmailSignalProbe.probeFrontBrowser() technique) for a known-Electron
  bundle list and read the active document/chat title from the web
  content tree as the windowTitle. Verify first on the Mac with:
  `osascript -e 'tell application "System Events" to tell process "Claude" to get name of front window'`
  on two different chats
  (expected: identical/blank → confirms). Mind the hot-path rules: AX
  walk must stay off the 2 s poll's critical path (no sync IPC on the
  sensor thread) and be node/depth-bounded like the email probe.
  Note (2026-08-07): `SessionTrackerChecks` now runs in-container on Linux
  as part of the platform-neutral checks subset – the away-mode gap
  described above is unchanged, this only means the suite covering it is
  no longer Mac-only to exercise.
  Note (2026-08-07, this commit): requirement (b) — Core recording — has
  landed. Focus/window changes during an away stretch now emit `FocusSpan`
  rows (target `.doNotTrack`, certainty 0, `observedWhileAway: true`,
  provenance `"observedWhileAway"`) via `SessionTracker.onSpanClosed`,
  emitted PER FOCUS CHANGE (not batched at the end) so a crash mid-away
  keeps everything already observed instead of losing the whole stretch.
  `FocusSpan.dominant(...)` and the app-breakdown aggregator both exclude
  these rows, so they can never win a session's identity or bill/teach/
  aggregate. Requirement (a) — the pinned attribution stays byte-for-byte
  undisturbed — holds by construction (a wholly separate shadow track;
  proven by a control-run comparison in the checks). The store's existing
  30-day spans prune horizon (JournalPrune) applies to this evidence same
  as any other span — the recovery flow below must not assume unbounded
  history. Requirement (c), the recovery flow, SHIPPED 2026-08-13
  (Settings ▸ Away rescue, engine replay + preview/apply — CHANGELOG;
  Martin chose "more auto", his end-time-orphan auto-apply extension
  landed same day). Mac-half span filters DONE 2026-08-14 (CHANGELOG):
  `observedWhileAway` rows are now excluded from `windowBoundaries`
  (snap edges), `reassignSpentApp` (carve ranges) and `timelineSpans`
  (the timeline's window-detail strip + span-reassign bar) — the away
  rescue readers keep reading them deliberately. Whole item closed;
  known consequence, revisit only if it annoys: a rescued/pinned
  stretch's slices show no window panes in the timeline (the Away
  rescue preview is the sanctioned viewer for that evidence).

- [ ] Once andeye.com serves the canonical /terms + /privacy: delete
  `site/docs/terms.md` + `site/docs/privacy.md` here and turn `site/src/pages/
  terms.astro` + `privacy.astro` (and LegalPage.astro) into redirects to
  https://andeye.com/terms/ and /privacy/. (The mailto→contact.andeye.com CTA
  swap landed 2026-08-01 once the form went live; only the legal-page
  redirects remain.) Until then the local copies
  are what time.andeye.com serves — the andeye.com repo's markdown is the
  single source of truth; never edit the prose here.

- [ ] Idle detection ends sessions during passive media watching: watching a
  YouTube video with no cursor/keyboard activity trips the idle timeout and
  stops the session, even though the video is playing and the user is present.
  AUDIO HALF BUILT 2026-08-14 (CHANGELOG): audible playback (output-device
  activity, app-agnostic — no per-site allowlist needed) holds off the
  idle timeout; idle counts from the moment the audio ends. Known flip
  side flagged to Martin (fromClaude 9): music left playing keeps the
  clock running. STILL OPEN pending his answer: whether presence should
  generalise beyond audio (muted video, long reads, remote desktop,
  presentations) — the broader "user is consuming" signal remains a
  design question.
- [x] AFTER the flip: restructure the live-tracking flush to save-before-clear.
  DONE 2026-08-14 (CHANGELOG): Mac — a failed flush save re-stages the
  slice in an in-hand buffer mirrored to a sidecar JSON (different failure
  domain than SQLite), retried at startup / every flush / every sync kick;
  phone — stop() deletes the crash checkpoint only AFTER the save lands,
  a failure holds the slice for lifecycle-tick retry with the checkpoint
  kept as the durable copy. InMemory mock's `update` aligned to SQLite's
  INSERT-OR-REPLACE (the phone checkpoint silently no-op'd on the mock).
  +1 phone check driving the full fail→hold→retry→release path.
- [ ] Claude desktop app attribution is too coarse: desktop-app time is
  recorded only as the app attributing to itself (the app name repeated in the
  evidence card and window history), with no per-project or per-conversation
  breakdown. Add sensing that distinguishes individual projects and individual
  chats inside the desktop app. Not a flip blocker.
- [x] Calendar candidate selection picks the wrong events: a week-long all-day
  event from a secondary calendar is offered as an attribution candidate while
  a genuine short timed meeting from the primary calendar on the same day is
  missed entirely. FIXED 2026-08-14 (CHANGELOG): `CalendarSelection` ranks
  candidates (timed > single-day all-day > multi-day; primary calendar
  first; then overlap, then the shorter event) for both the hint chip and
  the live prior; nothing excluded, so an all-day span still hints when
  it's all there is. Needs Martin's real-calendar feel.
- [ ] Restore the Xero "upgrade" link in Settings ▸ Pro connectors once the
  `/pro` page exists. Removed 2026-07-14 (pointed at a non-existent
  time.andeye.com/pro; dead link ahead of the public flip). The greyed Xero
  row and its licence caption stay; only the link button was dropped
  (SettingsView, "Pro connectors" section). Re-add pointing at the real page.
- [x] Pre-release review findings (2026-07-12) – all 15 actioned, plus
  follow-up fixes; details per-entry in CHANGELOG under
  2026-07-12. The publish steps themselves stay manual.
- [x] Attribution learning coherence pass (2026-07-13) – model written down
  (docs/superpowers/specs/2026-07-13-attribution-learning.md), first property
  coverage (L1-L7), one correction operator. No behaviour change. See CHANGELOG.
- [x] Learning behaviour fixes – GO all three (Martin, 2026-07-23) (this
  commit): (1) `forget` now subtracts an ESTIMATE of the erased signal's
  teach-weight from the target's `totals` (largest single-feature count
  erased), clamped to never go below the max surviving count for that
  target – a wholesale clear was rejected as it would have inflated the
  target's OTHER surviving associations; renders identically to a wholesale
  clear on the incident case (a target's only associations); (2) counts and
  totals now floor at 0 on write (`learn`), not just on read; (3) hourOfDay's
  teach-side weight matches its 0.15 score-side weight via one shared
  constant (`LearningStore.hourOfDayWeight`). RECENCY DECAY: re-analysed and
  NOT recommended – scoring is store-size-independent, closed backend tasks
  leave the candidate pool so stale associations self-clean, and "dropped"
  has no clean signal; leave associations and pins as-is. L7 pins the
  current no-decay.
- [x] Public API surface sealed to a three-tier contract (2026-07-12) –
  ~1,370 `public`→`package` demotions; spec at
  docs/superpowers/specs/2026-07-12-public-api-surface.md. See CHANGELOG.
- [x] Attribution certainty calculus written down and conformed (2026-07-12) –
  spec docs/superpowers/specs/2026-07-12-attribution-calculus.md, 8 property
  checks. Behaviour change: human-corrected slices post immediately (Martin
  ratified 2026-07-12). See CHANGELOG.
- [x] Posting/money state machine formalised (2026-07-12) – spec
  docs/superpowers/specs/2026-07-12-posting-state-machine.md, bounded
  model-check harness, three user-path holes closed. See CHANGELOG.
- [x] AFTER the flip: verify the iOS build against the API seal — DONE
  2026-07-17: Martin's `cd ios && xcodegen` + two clean Xcode builds passed
  first try; an independent same-day static trace of every symbol
  `ios/Sources` touches confirmed the seal (all public, no UI/Mac imports).
- [ ] Cross-repo (andeyePro session, tracked in the cross-repo note): Pro's
  Package.swift still depends on `../andeyeTT` product `andeyeTTCore`
  (pre-rename), so Pro cannot build against the renamed tree until its
  manifest updates; then re-verify Pro against community commit 2337b2a
  (confirmatory – every seam symbol Pro consumes stayed public).
- [ ] Non-blocking cleanups surfaced by the 2026-07-12 review (do after the
  flip, not before – each extra pre-release commit widens the review burden):
  TimelineView `selectTwins` O(N^2) per render; SettingsView connector panel
  hardcodes tiers (registry-driven rendering, Xero mis-filed as Pro);
  ColourEngineChecks pins real fixture names (synthesize the collision);
  EvidenceCardView `cardFactsAttributed` parallel fact renderer (one
  fact-model); extract a shared debounce helper (3 hand-rolled copies);
  `connectorHealth` recompute per connector (memo). Detail in the
  /code-review report at a private path
- [x] Light-mode contrast: `AndeyeColors.highlight` needs a light-scheme
  variant (light blue reads weak on white/blue; dark mode confirmed good).
  DONE 2026-08-14 (CHANGELOG): the highlight is now appearance-resolved —
  dark keeps the proven light blue, light mode gets a deep blue
  (canImport-guarded platform colour; iOS gets the same split). The
  snapshot harness now renders EVERY view in both appearances
  (-light/-dark suffixes), so this class of bug is visible to agent eyes
  from now on. Needs Martin's on-device look for the final word on the
  light-blue value.
- [ ] Re-shoot the deleted review-drawer screenshot with mocked data.
  
  longer in the tree. Nothing referenced it, but a replacement
  capture with fictional fixture data (harborlane.example-style) is wanted
  for the record.
- [x] Journal the decision SOURCE alongside task+certainty — DONE
  2026-07-10. `SessionProvenance` (raw source string + matched rule/key
  detail; string-raw so a case rename can't wipe old journals) is stamped
  by every `attribute()` branch, carried by the tracker through uncertain
  holds and provisional switches (reverts restore the pre-pend story;
  same-target inferred agreement never overwrites "you assigned it"),
  folded at flush as the run's duration-dominant decider (pinned runs =
  pin), and journalled on Session + FocusSpan (decodeIfPresent both ways).
  Reassign decision made: overwrite — provenance describes what STANDS
  (userAssigned / aiApplied / retro), the displaced story stays the card's
  history line; undo paths restore prior provenance (UnknownRepoint +
  RetroDigest carry it). BECAUSE now names the original decider verbatim.

- [ ] Positive fullscreen detector for menu-bar auto-hide users. With the
  System Settings auto-hide preference on, every desktop looks fullscreen
  to the visibleFrame heuristic, so FullscreenPose disables the
  float-over-fullscreen behaviour wholesale for those users (2026-07-10
  review) — their windows behave plain-normal and can be evicted when
  opened over a real fullscreen app. A richer detector could restore the
  behaviour: `CGWindowListCopyWindowInfo` bounds==screen owned by another
  app needs no extra permissions for bounds/PID, but wants care around
  multi-display, split view and edge cases — keep it simple and provable
  or don't ship it.

- [ ] Retire the com.andeye.mac transition shims once no pre-rename install
  remains on any Mac (transition began 2026-07-09): the LEGACY_BUNDLE_ID
  quit line + old-bundle retire block in scripts/make-app.sh, and the
  com.andeye.mac quit + ~/Applications/andeye.app retire in
  scripts/install-timeandeye.command.
- [x] Review-queue sub-minute floor + "Unknown" rename (Martin, 2026-07-09
  evening, BLOCKER for his testing) — DONE same evening: per-surface 60s
  admission floor (`meetingReviewFloor`, Settings-backed, applied at
  reloadReview + the retro re-add so persisted rows vanish with no
  migration; journal/timeline untouched); drawer button now "Unknown".
- [x] Timeline comment visibility (Martin, 2026-07-09 evening) — DONE same
  evening: pure `TimelineMath.foldLive` carries folded rows' comments into
  the displayed live block (+ in-flight note via shared `joinComments`);
  hover tooltips carry comments, commented slices wear a bubble mark; live
  editor shows folded comments read-only, edits only the note (lossless).
- [x] Finance-mapping Settings editor (D6 follow-up, 2026-07-08): DONE same
  day — registry-driven "Billing mappings" Settings section (visible only
  with a finance backend), billable projects each pick a finance-backend
  task; store persisted at finance-mappings.json; change handler persists +
  criterion-10 reopen + sync nudge. FinanceMapping simplified to task-id-
  only (connector resolves its own project) so the editor works through the
  seam's fetchTasks alone; store made lock-protected with a snapshot key
  table (the connector reads from the sync context).
- [x] timeandeyeTheme extraction (a sibling project request, 2026-07-08)
  — DONE 2026-07-10: SwiftUI-only target + exported product; AndeyeTheme
  (Colours incl. the moved highlight + brand amber, semantic Fonts scale)
  and AndeyeMark/AndeyeMarkView (first in-app SwiftUI renderer of the
  AndeyeLogo geometry — reveal + wink animatable, SVG-scaled stroke).
  timeandeyeUI consumes it; AndeyeColors stays as a compatibility spelling.
  4 render-contract checks; suite 669/0.
- [ ] Invoice NUMBER for the invoice-lock ref needs the Xero Accounting API
  (Projects API doesn't expose it — verified 2026-07-08); until then locks
  group under the single ref "Xero".

- [x] Relocate the AndeyeLogo geometry out of timeandeyeCore into
  timeandeyeTheme — DONE 2026-07-10 in a quiet development window.
  timeandeyeTheme is now a LEAF (its only Core use was this geometry), so
  a sibling app wanting just the brand takes just the theme target;
  timeandeyeMac gained the theme dep (AndeyeLogoImage renders the mark).
  Consumers repointed exactly as listed; suites 798/0; site literal-port
  comments updated. Cross-repo: a consumer
  importing timeandeyeCore for AndeyeLogo now imports timeandeyeTheme.

- [ ] NAIL Chrome/Gmail correspondent categorisation (Martin, 2026-07-03
  02:04 BST, priority — "spin out agents and absolutely nail it, take your
  time, run focus groups"). Symptoms: Gmail slices keep going to "University Teaching" and the why-panel can't explain why; the components/
  features list shows window-title junk ("High memory usage") and no
  correspondent addresses except his own; a painful learned outcome can't
  be removed. Deliverables: (a) diagnose + fix correspondent extraction on
  Chrome Gmail (EmailSignalProbe / Sensors page recipe — when did signals
  last carry correspondents?); (b) why-panel must show the email evidence
  (correspondent/domain/subject) whenever an email context exists; (c) an
  UN-LEARN affordance — remove a bad learned rule/association from the why
  panel; (d) pin by correspondent ADDRESS and DOMAIN without per-email
  pinning — design an intuitive UI (agent judge-panels over 2-3 mockup
  options before building); (e) generalise the mechanism beyond Gmail:
  pluggable page recipes for web apps where app/URL/title are insufficient
  (host-as-signal groundwork exists — see the ambiguous-web-page policy
  note, 6907245). Multi-agent programme; start AFTER the folder rename to
  timeandeye (andeyeTT → timeandeye on the Mac) and the vibe reopen.
  Progress: diagnosis written 2026-07-03 (a90fe90, RC1/RC2/RC3 root-caused).
  (a) DONE 2026-07-03, soak VERIFIED live 2026-07-09 — 313 enrichment events
  in the debug log with correct correspondents/subjects on real Gmail
  threads, app stable for hours. One live fault found in that log and fixed
  2026-07-09: list/label/search surfaces captured the LAST-open
  conversation's parties (Gmail keeps its DOM cached) and junk subjects
  ("Inbox (1)") — `EmailSystem.isMessageView` now gates capture kickoff to
  open-message URLs.
  (b)/(c)/(d) Core layer (ContextIdentity, EmailRule provenance, Attributor.
  forget/explainWithout) landed WIP 2e6f784 — UNVERIFIED, suite not run.
  (d) pin-editor slice landed 2026-07-03 (this commit): the popover's
  Components strip pins by correspondent/domain/subject visually, no typed
  expressions — see CHANGELOG.
  (b)/(c)/(d) Evidence Card UI phase landed 2026-07-04 (this commit) —
  `EvidenceCardView` (BECAUSE + [✕ forget]/[✕ suppress] with a live
  fallback preview, sees: line, grain ladder, Remember/Always, full
  keyboard ↑↓↵⇧↵esc) reachable from the popover's why-caption (⌘E) and the
  timeline's window panes; silent `learnEmailRule` retired from
  `confirm`/`assign` per spec §5.4, replaced by the card + the popover's
  post-pick grain footer; Rules Ledger (list + provenance + delete,
  Settings ▸ Email → task matching ▸ "Context rules…") — since verified,
  suite green on the bridge. 2026-07-09: first-learn notice (one line +
  undo, popover-anchored) + first-fire toast (Attributor.onFirstFire,
  fireCount 0→1 only), review-queue grain footer, multi-correspondent
  checkbox expansion (Evidence Card + review footer; one undoable notice
  covers the whole rule fan-out) — all landed, suite 491/0.
  Note: review-queue rows carry no stored correspondents, so their footer
  offers the narrowest AVAILABLE grain (often system-level) — enriching
  ReviewSegment with email evidence is the follow-on if wanted.
  2026-07-09 (follow-on landed): `ReviewSegment` now stores the
  correspondents/subject its signals carried at queue time (merged across
  same-surface extensions: correspondent union, first non-empty subject),
  rides through stacking/floor/persistence untouched (evidence lives in
  the existing JSON blob column — no schema change, legacy rows decode
  nil), and the footer offers the full correspondent/domain/subject
  ladder; a batch whose evidence disagrees degrades to the shared
  mail-system grain instead of losing the offer. UNVERIFIED — suite not
  run (no Mac in this container).
  2026-07-09 (later polish continued): ledger row click now expands into a
  compact rule-detail disclosure (provenance sentence, fire stats, grain,
  target task — `EvidenceCardView` itself doesn't fit here, a ledger rule
  has no live signal to explain); bulk forget via per-group "Forget all"
  buttons, one undo restoring the whole group (`AppController.deleteRules`,
  `deleteRule` now a one-row call into it); "Copy rules" plain-text export
  (`RulesLedger.exportText`, Core + checked) mirroring the timesheet
  export's copy-button/"Copied" pattern. UNVERIFIED — suite not run (no
  Mac in this container). Still open: candidates ▾ expansion (spec §6
  "later polish");
  screen-share suppression DONE 2026-07-09 ("Quiet while presenting" —
  mic-live/display-mirrored gate on naming banners).
  (e) DONE 2026-07-09 (this commit) — site recipes v1 per the 2026-07-09
  site-recipes spec: SiteRecipe/SiteContext model + GitHub/GDocs/Xero
  Tier 0 built-ins, SiteRule/SiteMatcher third rule domain on the email
  rung, recipe ContextIdentity chains (replace-not-splice), grain commits
  from card + both footers, `site` host grain on every web page,
  `.recipeField` learned features, ledger Sites segment + recipe toggle
  strip, diagnostics "What recipes see here", six check suites; see
  CHANGELOG. ⚠️ Xero's URL/title shapes are asserted from memory — verify
  live with the diagnostics row and fix recipe + fixtures together if
  they differ. Gmail NOT migrated into the model (spec §11 later, with
  the pack/update channel, point-and-teach recipes, Tier 1 beyond mail,
  and the three-domain rule-protocol refactor). UNVERIFIED — suite not
  run (no Mac in this container).

- [x] BEFORE the FOSS publish: contributor IP mechanism. (DONE 2026-07-02 —
  Martin chose AGPL-3.0 + CLA; LICENSE, CLA.md and the CONTRIBUTING licence
  section landed in one commit. Still on the publish click-list (WP 223):
  Martin reviews the CLA text, and the enforcement check (CLA-assistant or
  PR-template line) is wired before the repo flips public.)
- [x] Generalise duplicate-reconcile beyond OP (2026-07-02, from the
  TaskRef.remote migration). (DONE 2026-07-02, 11c6d0a — RemoteTimeEntry is
  a real Core struct with String ids; ReconcileAction backend-neutral;
  OPBackend converts at its edge.)

- [x] iCloud quota stewardship (Martin, 2026-07-02; DONE 2026-07-09). (a)
  Settings ▸ Maintenance shows the real footprint (`JournalStore.journalFootprint()`
  — synced-session bytes vs local-only window-span bytes, SQL SUM(LENGTH(json)),
  never a full-table decode). (b) age-consolidation prune (`JournalPrune.plan`,
  already built + check-covered pre-existing) is now wired to the store
  (`AppController.consolidationPreview`/`applyConsolidation`) and a Preview →
  Consolidate now control in Settings; `journalConsolidateAfterYears` setting,
  default 2. (c) hard-cap prune (`JournalPrune.hardCapPlan`, new — oldest raw
  slices first, `SessionMerge.isDerivedID` keeps rollups off-limits) wired via
  `applyHardCapPrune`, `journalHardCapMB` setting, UI double confirm
  (two chained `confirmationDialog`s). (d) tombstone GC turned out to be
  ALREADY SHIPPED (`SQLiteJournalStore.purgeTombstones`, runs on init) —
  nothing to build. NEEDS Mac-side `swift run timeandeyeChecks` + on-device
  Settings verification (built clean only, container has no Swift toolchain).

- [x] Full keyboard/mouse parity sweep (DONE 2026-06-28). Audited every
  interactive control (Explore inventory): every action has a mouse path. Added
  ⌘-shortcuts across the popover (⌘T/⌘P/⌘./⌘R/⌘Z/⌘Y/⌘U/⌘,/⌘Q, ↵ picks top task)
  and the Time window (⌘\\ flip, ⌘[/⌘]/⌘−/⌘+/⌘B/⌘0 timeline, ⌘1–4/⌘⇧O/⌘⇧C pie,
  ⌘⌫ delete-in-editor), plus Review (⌘D/⌘⇧C/⌘↵). Settings/Review forms use
  standard Tab/Space/arrow navigation. Chords are in tooltips and MANUAL.md.
  NEEDS on-device verification that key-window shortcuts fire (built clean only).
  STANDING RULE going forward: every new command ships with a keyboard path, not
  just a button.
- [x] Pin editor AI mode (DONE 2026-06-28). Fourth hamburger entry "AI":
  `AIAssist.pinRulePrompt` builds a prompt from the captured app/title/url + an
  editable guidance box (pre-seeded with the stable-pattern nudge,
  `AIAssist.defaultPinAdvice`), shown scrollable and auto-copied; the paste-back
  is cleaned (`AIAssist.cleanRuleReply`) and parsed by the existing
  PredicateParser into an editable Expression rule (↵ applies → review → ↵ pins),
  or shows the parse error. A "Fix with AI" button on an Expression parse error
  hands the failed rule to AI mode. Core builders unit-checked (181 checks). UI
  flow needs an on-device check (built clean only).
- [!] Workspace layouts — CUT 2026-06-23 (UI removed; capture/apply code left
  dormant). As built it restored only window app + position/size, never content
  (Chrome tab/URL, terminal cwd), and multi-window/Spaces spawning was
  unreliable (windows in the wrong Space, blank, mis-sized). Re-add ONLY with:
  per-app content restore (Chrome tab via AppleScript, terminal cwd), reliable
  multi-window spawning, and Space detection so it needn't start from a fresh
  empty desktop. Done right this is the "right-click a task → open its
  workspace and start working" killer feature; done as-was it was net-negative.
- [ ] Pin rules — visual boolean builder: a drag/click gate builder (AND/OR/NOT
  + parens) as an alternative to the typed expression. If too heavy for the
  app, host it as a static webpage: app opens it with the captured fields in the
  URL, the page builds the expression, and returns it via an `andeye://`
  deep-link (or copy-paste). Keeps the app slim. Phase-1 ships the typed
  expression; this is the friendlier front-end. - 2026-06-24
- [x] Pin rules — priority override (DONE 2026-06-28): default precedence is
  most-specific-wins (more conditions / longer prefix), ties → most recent.
  Add an optional per-pin `priority` integer in an Advanced section for manual
  override. Hook already in the `Pin` model (`priority: Int?`); just needs the
  UI. - 2026-06-24
- [ ] Pin rules — "look inside" apps (opt-in window-content matching): some apps
  expose nothing useful in app/title/url (e.g. a generic "Spango" window). For
  an explicit per-app allow-list ONLY, read static text from the window's
  Accessibility tree into a 4th rule field `content`, throttled/on-demand so the
  default stays featherweight (full AX-tree walks are heavy — must not regress
  Mac performance). Not all apps expose AX content; detect and tell the user.
  - 2026-06-24
- [ ] Email SENDER as a first-class signal (the big Gmail flaw, 2026-06-29).
  Root cause: capture only sees app/title/url, and a Gmail browser tab title is
  `<subject> – <account> – Mail`, URL is `/mail/u/0/#<volatile-hash>` — the
  SENDER, the most useful "which task" key for mail, is in NEITHER. Both a
  by-account pin (too broad) and a by-subject pin (too narrow) are forced
  compromises. Fix = a new captured signal, not a new operator:
  • Read sender (and ideally the focused-message from-row) via a TARGETED AX read
    (extends the "look inside" `content` work above; on-demand, not a tree crawl).
  • Expose it BOTH as a learner feature (auto-attribution keys on sender with no
    pin) AND as a pin field `from`/`sender`.
  • Specificity ordering: when pinned, SUBJECT trumps SENDER (more specific), so a
    subject match outranks a sender match in precedence.
  • New `any` field: `any contains "X"` (and bare keyword) must search across ALL
    fields — app/title/url AND the new sender/content — not just the original three.
  • Do this for ALL major email systems (Gmail, Apple Mail, Outlook desktop +
    OWA, Proton, Fastmail, Yahoo, …) via SMART GENERALISATIONS, not N hand-coded
    scrapers. Native clients (Apple Mail/Outlook) often expose sender in the
    window title/AX already — easy; browser webmail is the hard case.
  • Self-learning: an unknown/new email client should be assessable automatically
    — the system derives where the sender lives from the AX tree, or makes a
    SYSTEM-REQUESTED AI call (reuse the AI-assist clipboard flow / future API) to
    locate it, then remembers the per-client hint. Prototype = (b) below.
  Architecture (refined 2026-06-29):
  • Detect-and-dispatch: identify the system from URL host (webmail) / bundle id
    (native); look up its recipe in a recipe store and apply it as a TARGETED read.
  • A recipe is a SELECTOR (role + From/Sender label + focused-message
    disambiguator + version), NOT the probe output — the probe yields candidate
    addresses, not which one is the sender, so learning a new system is
    probe → LABEL → store-recipe, never probe → store.
  • Cheap validate-on-use runs EVERY time (did the recipe resolve to exactly one
    plausible address?); only a FAILURE triggers the expensive re-learn (the else).
    Handles webmail redesigns + localized "From" labels via self-heal.
  • Ranked candidates: score each address by sender-likeness (proximity to a
    From/Sender label, header-link role > body static-text, top-of-header position,
    NOT the account's own/self address, NOT in the recipient row, inside the
    focused/expanded message). Above a confidence threshold → use the top silently;
    below → show the ranked list and ask "which is the sender?" (one tap hardens the
    recipe). Mirrors the existing auto-push-above-certainty model.
  • "Ask AI" whole-diagnostics button: hand the full AX dump to the model to pick
    the sender AND emit a reusable selector (clipboard flow now, API later).
  • Distribution: SHIP a bundled recipe pack (offline, zero setup) covering the top
    providers up to diminishing returns (Gmail, OWA, Apple Mail, Outlook, Proton,
    Yahoo, Fastmail…); auto-detect — NO setup checklist (friction + goes stale).
    Add BACKGROUND recipe-pack updates so a provider redesign is fixed centrally
    for everyone without an app release (recipes are data, not code → low risk,
    validation guards). Monitoring for a "new/unknown client" is then free: it's
    the same detect step → gentle "want me to learn your mail here?" nudge.
- [ ] Email auto-learner — Core engine SHIPPED 2026-06-30; Mac capture
  RE-ENABLED 2026-07-03 (`EmailCaptureEngine`: async, deadline-bounded,
  one-in-flight `osascript` subprocess — the 6-30 `NSAppleScript` freeze can't
  recur) and soak VERIFIED live 2026-07-09 (313 clean enrichment events).
  Correcting an email's task learns an EmailRule; matching mail
  auto-attributes via the `.emailRule` source through the user's reorderable
  ladder (Settings chevrons, 2026-07-01). Explicit `from`/`sender`/`subject`
  + `any` pin fields shipped 2026-07-01. Own addresses/domains now come from
  Settings ▸ Email "My addresses/domains" (2026-07-09) — alternates like
  martin@example.com no longer appear as correspondents.
  Validate-on-use + per-system health telemetry SHIPPED 2026-07-10
  (`EmailRecipeValidation`/`EmailRecipeHealth`: every error-free read judged
  healthy / self-only / suspect; suspect reads never enrich; 3 consecutive
  failures mark the system unhealthy, log it, and fire the engine's
  `onRecipeUnhealthy` seam). Webmail recipe pack SHIPPED 2026-07-10
  (OWA/Proton/Yahoo/Fastmail: anchored host detection, per-provider
  message-view gates, provider-neutral address ladder in the capture JS;
  selectors evidence-researched — Proton authoritative from WebClients
  source, OWA/Yahoo cross-corroborated across extensions, Fastmail weak —
  but NONE verified against a live DOM yet: validate-on-use is the guard,
  per-recipe provenance in `EmailSystem`'s comments).
  REMAINING (single list — the two sibling entries below point here): live
  verification of the four new webmail recipes (open a real message per
  provider, watch the health probe); native clients (Apple Mail/Outlook
  desktop — a different capture channel: AX/window-title, not page JS);
  the re-learn/self-heal loop (probe → label → store-recipe, attaches at
  `onRecipeUnhealthy`) + recipe pack with background updates;
  multi-message-thread sender choice.
- [ ] (b, 2026-06-29) Gmail sender extraction — CHANNEL + RECIPE FOUND, and
  threaded into a live signal 2026-07-03 (see the capture-layer entry below).
  Chrome's renderer AX tree stays off (AXManualAccessibility didn't wake it), so
  the channel is page JavaScript over Apple Events (needs Chrome ▸ View ▸
  Developer ▸ Allow JavaScript from Apple Events). Validated Gmail recipe:
  `.gD` = open-message sender, `.g2` = recipients (a blanket `[email]`/
  `[data-hovercard-id]` query is polluted by the ~100+ inbox-list `.yP` rows Gmail
  keeps in the DOM). Gmail names your own address "me", so counterparties fall out
  cleanly. Foundation shipped: `EmailSystem` (detect + per-system selectors),
  `EmailSignal.Party`/`counterparties`/`domain` (pure, tested),
  `EmailCaptureEngine` (async, `osascript`-subprocess, recipe-driven; the
  diagnostics probe shares it too). It IS a live signal since 2026-07-03
  (soak verified 2026-07-09; list-view stale-DOM capture gated same day).
  REMAINING: see the auto-learner entry above — one list, not three.
- [ ] Pin rules — AI "fix this pin": from a pin that should have matched a
  window but didn't, regenerate the AI prompt including the failing rule + that
  window's fields + a free-text complaint, so the model corrects it. Iterative
  refine on top of the one-shot AI pin flow. - 2026-06-24
- [x] Backend seam + standalone mode (protocol half DONE 2026-07-01, see Rank 9
  above): `TaskBackend` extracted, OP behind it in-process, standalone = nil
  backend, activity picker hidden when the backend has none. Still open from
  this item: CSV/Markdown timesheet export (next), standalone comment storage.
  Plugin loader deferred until a second backend exists. - 2026-06-22
- [x] Right-click 'Open in <backend>' + Comments… — DONE 2026-07-08
  overnight: pick-list rows gain a context menu with "Open in <backend>"
  (connector taskURL; hidden standalone) and "Comments…" (a sheet listing the
  timestamped locally-stored notes — the read half of comment-to-task).
- [x] Standalone 'comment to task' storage — storage half shipped earlier
  (task_comments table + fallback writes); the READ surface landed 2026-07-08
  overnight with the Comments… sheet above.
- [x] Semantic-ish task search (DONE 2026-07-01): `searchTasks` now also matches a
  task by the words the learner has associated with it — `LearningStore.
  learnedValues(for:)` (titleToken/urlHost/app) fed into `FuzzyMatch.filter` via a
  closure, gated at substring-or-better. So "voting" finds the task you always do
  in a voting window even when its OP subject never says it. Not LLM-semantic, but
  covers the real case. Unit-checked.
- [x] Named local-only tasks creatable from the Review window (DONE — already
  present: the "…or new non-OpenProject task" field + "Create & assign" button →
  addLocalTask, verified 2026-07-01). Leisure flag not exposed there (minor).
- [ ] iOS app (Core is ready). ROLE (Martin, 2026-07-01, revised same day):
  iOS senses no other apps (impossible on iOS, ever — per the design spec),
  but the app is NOT companion-only: it must stand alone as the best manual
  time tracker on the iOS store (and best value), with the Mac app as a
  superpower on top, so iOS-only users are first-class. iOS-legal "sensors"
  replace window-watching as the USP: location, calendar events, Focus modes
  and time-of-day feed the SAME Core attribution ladder + learner (arrive at
  the studio → the studio task surfaces; meeting in the calendar → offer it
  as a slice). Plus Live Activity lock-screen timer with one-tap switch,
  interactive widgets, Watch complication, App Intents/Shortcuts, and direct
  OpenProject/Xero push (no iOS tracker does OP today). Second-screen + remote
  for Mac users: show what's tracked now, one-tap switch/change, one-tap
  manual tracking away from the Mac. Realtime channel PROPOSAL (undecided): CloudKit private DB —
  the Mac stays the single journal owner; iOS mirrors a small live-state
  record (current task, certainty, today's totals, ranked pick list) and
  writes COMMAND records (switch/stop/manual slice) that the Mac folds into
  the journal (the "entered via a secondary app" window kind already exists in
  the model). Works away from home (the whole point), no server to run, free
  tier ample, offline commands queue and merge on Mac wake. Alternative
  rejected for v1: LAN Bonjour/WebSocket to the menu-bar app (instant but dead
  off-LAN); OP-as-rendezvous (breaks standalone, and the backend shouldn't see
  second-by-second state). DECIDED 2026-07-01: it lives IN THIS REPO, not a
  new one. Rationale: the iOS app is a
  thin SwiftUI shell over timeandeyeCore, and pre-1.0 Core API churns weekly — a
  separate repo forces either a tag-per-change SPM dance or fragile local-path
  references, and every cross-cutting change becomes two PRs. In-repo, one
  commit updates Core and both shells, and the one check suite guards both.
  Shape: an `ios/` Xcode project (App Store needs signing/provisioning that
  plain SwiftPM can't do; the CLT-only make-app.sh trick is Mac-specific)
  referencing the local package at `../`; Core stays AppKit/UIKit-free as the
  spec requires. Revisit a split only if release cadences genuinely diverge
  post-release — and try release branches before a repo split even then.
  RE-EXAMINED 2026-07-01 with iOS-standalone in scope: same answer,
  reinforced — an iOS-only user connecting to OP/Xero runs OPBackend/Core
  directly, so Core is the shared product on both platforms. The eventual
  free/paid split is by SPM MODULE, not by repo: if Pro backends go
  closed-source, they move to a private `andeyePro` package the release
  builds depend on — the TaskBackend seam makes that a clean lift.
  Engine-side slice-repair landed 2026-08-07: `PhoneController.reassign`/
  `adjust`/`deleteSlice` let a banked (already-`stop()`-pushed) slice be
  re-pointed, resized, or withdrawn, obeying the same `PostingSever` lock +
  compensation laws as the Mac's timeline editor. The SwiftUI surface in
  `ios/` that calls these is still open — undo/redo on the phone is
  explicitly out of scope for that surface too, deferred alongside it.
- [ ] Safari tab URLs — CODE LANDED 2026-07-08 overnight ("URL of front
  document" branch beside the Chrome-like verb; Opera was already in the
  chrome-like set). HARDWARE-VERIFY pending: first Safari focus should fire
  the Automation prompt; confirm URLs flow. Chrome-PWA AppleScript support
  still open.
- [ ] In-app onboarding flow (user 2)
- [x] OP project-slug matching — DONE 2026-07-08 overnight: the project-page
  ranking boost is now SCOPED to the URL's project (slug after /projects/,
  matched against the stable project id or the slugified title); unknown
  slugs keep the old everyone-boosted fallback. Checked.
- [ ] iPhone-side call detection
- [ ] Auto-comment as debugging aid is OFF by default now; revisit whether
  window summaries have any user value (Martin: prefers manual note only)
- [x] Attribution auto-prime (DONE 2026-06-28): a newly-created local task wasn't auto-associated
  with its window, so its time files under the previous task until the user
  reassigns once (reassign now teaches the association, so it self-corrects
  after the first fix). Consider auto-priming a local task to the frontmost
  window at creation time.
- [x] True global hotkey for "I'm leaving my desk" (DONE 2026-06-28) (currently ⌘⇧L works when
  andeye/its popover is key; a global RegisterEventHotKey would fire from
  any app).
- [x] Ambiguous web pages — POLICY DECIDED 2026-07-23 (Martin: "Yes stay on
  current task (but monitor window/tab change)"). When nothing matches (no
  pin/OP/learned host): STICKY — keep the current task, read low-certainty
  (red), keep monitoring surface changes; reassign-mode click re-points the
  current window/tab and teaches the host (one correction generalises the
  whole host, the web sibling of the email domain ladder). Truly transient
  pages (new tab, a search) keep the prior task.
  CORE HALF LANDED 2026-08-07 (site-recipes spec §11 "later" item unparked):
  `Attribution`/`AttributionExplanation` gained `ambiguousSurface` — true
  iff a signal fell all the way to the ranked tier (no pin/sticky/OP-URL/
  OP-title/email-rule/site-rule/prime fired) AND it's a web page whose host
  has neither a `site`-level `SiteRule` nor any learned `urlHost`/`urlPath`
  association (`LearningStore.hasAssociation(urlHost:)`, additive). Computed
  fresh every call, never latched — the next signal with rule-grade evidence
  or a learned host attributes normally. `SessionTracker`, while `.tracking`
  a real task, reads the flag to refuse opening a pendingSwitch off an
  ambiguous page's own ranked candidate; the held/displayed certainty is the
  live-adjacency/continuity score instead (0 once the boost has decayed),
  never the pre-ambiguity value, so the slice reads red and queues for
  review. `explain()` mirrors the same flag so a why-panel re-derivation can
  never disagree with the live hold.
  STAYS MAC-SIDE (not this commit): the reassign-mode click that teaches the
  host from a click (writes the `site`-level `SiteRule`); the popover's
  visible red-certainty display itself; his OPEN sub-question — make the
  reassign SCOPE visible (popover shows time-on-current-window beside the
  running total so "only the last 1 minute reassigns" is legible before the
  click) — ties into the elapsed-desync item (menu bar vs timeline) below.
- [ ] Martin to verify: timeline edits write back correctly to OpenProject and
  no data (windows etc.) is lost across edit/merge/split/reassign.

## Billable flag + multi-backend (2026-07-06)

- [x] Billable flag (andeyeTT) + multi-backend fan-out (postings ledger,
  backend classes pm/finance) – spec at
  docs/superpowers/specs/2026-07-06-billable-flag-multibackend.md.
  BUILT 2026-07-06 as /vs task_002 (see that section below); per-project
  finance routing stays a long-term item there.

## Approvals drawer (2026-07-06)

- [x] Approvals drawer v1 (DONE 2026-07-09, per Martin's answers that
  morning): retro auto-acceptance at the push bar (clears queued rows a
  later rule makes confident, lifts + re-points their UNPUSHED overlapping
  sessions so they post; live-checkpoint and already-pushed rows are never
  touched), journal-backed 30-day "Recently cleared" digest with one-undo-
  per-pass, STACK-BY-DEFAULT drawer (identical surfaces collapse to one
  decision: "[total] over N slices, first – last", expandable; his flip
  idea), decision-count badge (stacks, not slices — days-framing rejected),
  review threshold now a visible setting beside the push slider. Spec at
  docs/superpowers/specs/2026-07-06-approvals-drawer.md.
- [ ] Approvals drawer — parked pending Martin: aging-to-archive (his "not
  so sure"), trust mode (ditto), weekly summary ritual, invoice-range
  approve (spec §4/§5/§6 later scope).
- [x] Unknown task category (Martin, 2026-07-09; DONE same day): built-in
  sentinel local task (never in the pick list), "Not sure – Unknown" beside
  Do-not-track in the review assign bar, sweeps re-point overlapping
  unpushed low-certainty sessions at their CURRENT certainty (no lift, no
  teaching — an explicit "don't know" is not a correction), hatched grey in
  the timeline / fixed grey in the pie, and the retro pass scores
  Unknown-assigned segments alongside the queue so a later confident rule
  reclaims them automatically (digest says so honestly). Known tradeoff:
  undoing a retro pass returns reclaimed segments to the visible queue, not
  back to Unknown.
- [x] Timeline drag/shift-click a span → allocate (DONE 2026-07-09): shift-drag
  or shift-click-extend selects a time RANGE (not bound to any slice's edges),
  shown as a translucent band; a small bar offers Allocate…/Unknown/Cancel.
  `SpanAllocation.plan` (Core, checked) classifies each overlapping session as
  a whole repoint or an edge split, reusing `TimelineMath.split` and the
  existing `reassignTimelineSessions`/`replaceSession` paths so pushed
  sessions and undo behave exactly as they already do elsewhere; Unknown
  never teaches (`teachAssociation` now guards on `Target.teachesAttributor`,
  closing a latent gap where Unknown was never actually reachable from that
  helper's other callers before).
- [x] Calendar signal v1 (Martin's GO 2026-07-09, "you should know in
  realtime what I'm supposed to be doing"; spec
  docs/superpowers/specs/2026-07-09-calendar-signal.md; DONE same day):
  read-only EventKit CalendarBridge (change-notification + wake + 5-min
  fallback, never a poll; lazy permission on first enable), CalendarRule
  ladder mirroring email (correction-taught on the same paths,
  Unknown-guarded), TaskRanker calendar term feeding BOTH the attributor's
  ranked fallback (bounded by the 0.9 cap) and the pick list, clock badge
  on the live-matched task, popover mismatch banner with Switch, quiet
  menu-bar flash (ships OFF pending Martin's OK), review-stack hint chips
  from past events. Later per spec §10: segmented ledger + manual rule
  form, screen-share suppression, iOS glance, next-event lookahead.
- [x] Calendar defaults confirmed + meeting alerts (Martin's answers,
  2026-07-09, same day): (a) and (b) verified already held in v1
  (birthday/subscription calendars excluded by type; the calendar term
  structurally capped below pin/sticky/URL/email — now pinned by the
  CalendarPrecedence checks); (c) the off-calendar mismatch flash is
  SUPERSEDED by time-based alerts: quiet pulse through the lead-up
  (1/2/5/10/15 min picker, default 5), violent flash at meeting start,
  both default-ON, no retroactive flash, tentative pulses-only, all-day
  never alerts, whole Settings subsection hidden while the signal is off;
  the popover Switch banner stays. Pure scheduling in Core
  (`CalendarAlerts`), CalendarAlerts check suite.

## Colour strategy (2026-07-06)

- [ ] Colour strategy – stable project/task/window colours – spec at
  docs/superpowers/specs/2026-07-06-colour-strategy.md, lab at
  sites/previews/colour-lab.html. ENGINE v1 SHIPPED (Martin's "build it",
  2026-07-09): hue-neighbourhood allocator in Core (`ColourEngine`),
  first-sight colours.json records, legacy-hash migration snapshot,
  stable project-anchor ring/legend colour, checks. MIGRATION REPAIR
  (2026-07-10): v1 snapshotted task colours but allocated FRESH anchors
  for already-seen projects (Martin: dull projects, unrelated bright
  tasks); anchors now snapshot/repair to the pre-engine first-child
  colour via record provenance. Remaining per spec:
  click-swatch editing everywhere (legend, ring-3), inherit/fixed with
  "i" marker + swatch popover editor, window/surface colour records (pin
  identity grain), Life period with All/Tracked/Untracked, colours.json
  sync (whole-record LWW) + iOS PhonePalette sharing the store (until
  then iOS still hash-derives, so auto colours differ across devices).
- [x] Pie colour editing (Martin, 2026-07-10: "I can see no way of
  editing any colours in the pie") – SHIPPED 2026-07-10: legend
  project/task swatches (and each row's "Edit colour…" context item)
  open the spec §5 popover editor — native picker + "Reset to
  automatic", undoable, project picks steering future task shades via
  `settings.projectColours`. Ring-3 window wedges stay derived-only (no
  per-window colour identity yet — that is the pin-identity-grain item
  above); wedge right-click deferred with them.

## Hardware-test UI fixes (Martin, 2026-07-06) — Mac verification pending

- [ ] Martin to verify on the Mac (container has no macOS, can't build/run):
  contrast fix (`AndeyeColors.highlight` replacing accentColor-as-text in the
  pin editor, Evidence Card, Rules Ledger), pin-editor confirm now rightmost,
  Evidence Card wrap-not-truncate + click-stability (`.animation(nil, ...)`),
  fallback "✕ forget that fallback too" button, Rules Ledger delete as a red
  trash icon behind a confirm dialog + inline Undo banner. See CHANGELOG
  2026-07-06 for the full breakdown; `swift run timeandeyeChecks` covers the
  pure logic (`forgettableWithout`) but none of the SwiftUI layout/animation
  claims — those need eyes on real hardware.

## /vs task_002 – multi-backend + billable (2026-07-06)

- [x] Build the multi-backend seam + billable flag per the multi-backend spec
  (BUILT 2026-07-06, cycle 1; fuzzy mode – Reviewer verdict + Martin's
  `swift run timeandeyeChecks` on the Mac pending). BackendRegistry +
  pm/finance classes, per-(session, backend) posting ledger with one-time
  single-slot migration, billable project Bool + task tri-state in
  billing.json (stable project-id keys via the OP conformer's new href
  capture), prospective-only flips with the stranded-hours alert, currency
  symbol setting, `AppController.register(backend:id:class:)` seam,
  Billing/MultiBackendSync check suites. See CHANGELOG 2026-07-06.
- [ ] Long-term (billable): per-project finance-backend routing (which
  Xero org invoices which project); catch-up "special invoice" for time
  stranded by a billable flag-flip (warning ships in task_002; mechanism
  later).
- [ ] Ledger follow-ups (from the task_002 build): posting-ledger rows do
  not yet join the CloudKit journal sync (single-pusher lease covers one
  device today – a second device could re-post; wire ledger rows into the
  2026-07-02 sync design before multi-device + backends coexist); timeline
  edits PATCH/delete only the primary pm entry – a posted finance entry is
  left as-is by later edits/deletes (prospective-only by design, but a
  reconcile-style finance read-back tool would close the gap); journal
  summary counts ("awaiting push") remain pm-centric.

## Window detail selection helpers (Martin, 2026-07-07)

- [x] [+all] button — DONE 2026-07-08 overnight: "+ all" appears top-right
  of the detail strip whenever the
  current selection has unselected twins (identity = app + title + tab URL,
  never the times); one click extends the selection to all of them; help
  text counts what it will add. Full build + suite green on the bridge.
- [ ] [+similar] button (later, non-critical) — pressable repeatedly to
  accumulate windows similar to the current one; a paired [-similar] steps
  the accumulation back so you can undo over-pressing. After [+all].

## Comment-loss edge (2026-07-07, pre-existing, low priority)

- [ ] A committed comment (in manualNote) on a slice that is then DROPPED as
  a sub-grace flit and immediately followed by a stop is lost at
  AppController onState (:598 clears the un-banked note). Rare; pre-existing
  (predates the enter-to-commit rework). Fix would bank a pending note onto
  the nearest kept slice, or hold it for the next slice, before the stop
  clear. Flagged by the reassign/comment review.

## Timeline/menu-bar issues from hardware test (2026-07-07, Opus, post-Fable)

- [x] Elapsed desync: menu bar and timeline agree on the TASK now but not
  the ELAPSED — Martin saw menu bar "2s and counting" vs timeline "8 min"
  for the same task (a client project). AUDITED + PINNED 2026-08-14
  (CHANGELOG): the under-count direction is structurally impossible now —
  the menu's displayedElapsed takes max(open-slice elapsed, banked+running)
  whenever the shown task OWNS the open slice (liveSliceOwner gate), and
  the timeline's live block reads the same liveSliceStart, so a reassign
  resets both clocks together (new asserts pin owner + start at the
  scoped-relabel cut). Decided semantics, kept: the menu may legitimately
  show MORE than the live block when it recovers this task's earlier
  banked visits (clock continuity across excursions — the recorded slices
  for those visits are on the timeline). fromClaude 10 informs Martin.
- [ ] Time window over a full-screen app: today a regular Window opens in
  its own Space so it can't overlay a full-screen app. NOT impossible —
  mark the Time window as a floating auxiliary panel (NSWindow
  collectionBehavior .fullScreenAuxiliary + .canJoinAllSpaces, or an
  NSPanel .nonactivatingPanel) so it can float over full-screen. Opus job.

## Deferred from the overnight review (2026-07-08, queued with context)
- [ ] B7: Surface identity drops URL query/fragment for non-mail sites — one
  correction re-points ALL query-routed pages (?v=, ticket ids, SPA #/routes).
  Needs the known-host recipe mechanism extended (mail-style) WITHOUT breaking
  persisted primed.json keys. Design first.
- [x] B12 — DONE 2026-07-08 (window 2): render escapes quotes/backslashes,
  the tokenizer unescapes; unknown escapes pass through so old rules parse
  unchanged; round-trip check added.
- [x] B13 — DONE 2026-07-08: Predicate.invalidRegexPatterns walks the tree;
  both editor save paths (typed expression + AI reply) refuse a broken
  pattern naming it; check pins the flag incl. nested trees.
- [x] B16 — DONE 2026-07-08 (window 2, a4d02c9): recent-first block capped at
  two recency half-lives; ancient one-offs rank normally below live Now tasks.
- [x] B10 check — DONE 2026-07-09: the pinned-excursion scenario now asserts
  the other target's window title never leaks into this task's auto comment.
- [x] C10 — DONE 2026-07-09: every emitter funnels through SensorHub.emit,
  which asserts main-thread and hops if a future emitter (the AXObserver
  refinement) ever calls from elsewhere.
- [x] C13 — DONE 2026-07-08: ⌘Z monitor token stored and removed at
  willTerminate alongside the Carbon hotkey.
- [x] C14 — DONE 2026-07-08: init uses last launch's cached display-sleep
  (default 600 s); startUp refreshes via pmset off-main, applies live
  (SessionTracker.setIdleThreshold) and re-caches.

## Fable session outputs (2026-07-07 night — review + code, NOT yet Mac-verified)
- [x] D0 anti-entropy audit — DONE 2026-07-11 (vsss iter-35): D0.1 (F21
  re-assert local wins) and D0.2 (F22 ≤200-record push batches) were already
  built and Mac-verified in the licence/sync batch; criterion 12 and the
  chunking half of 13 were already pinned. The one gap was criterion 13's
  FAILURE clause — now pinned by a new JournalSyncer check (a mid-backlog
  batch rejection keeps only the failed chunk + un-attempted tail dirty;
  the landed chunk is never re-uploaded). 836/0 on the Mac. D0.3 (surface
  decode drops as "N sessions from a newer version aren't visible") remains
  open — user-facing, deliberately deferred.
- [x] RUN `swift run andeyeTTChecks` on the Mac — DONE 2026-07-08 00:2x BST
  via the Mac test bridge: TOTAL 441 passed, 0 failed (twice).
  Needed `rm -rf .build` on the Mac tree (stale module cache) and one
  pre-existing flaky check deflaked (ContextRules surface bytes).
- [ ] Licence tiers LOCKED by Martin 2026-07-23, superseding the spec's open
  Qs: community (includes OpenProject) / plus (ONE standard connection —
  currently Xero is the only one — + 24h email response) / pro (ALL standard
  connections + 12h) / premium (all premium connections + 2h) / enterprise
  (contact us). Fold into the licence spec §1 next session; open sub-question
  to Martin (fromClaude): which connections count as premium. Unchanged rule:
  do NOT sell any paid SKU before the entitlement gate ships end-to-end.
- [x] AI-review triage — DONE 2026-07-11 (vsss iter-36 reconciliation).
  Designs: docs/superpowers/specs/2026-07-07-multidevice-posting-
  correctness.md (D0–D7 + 14 criteria). SHIPPED and code-verified: F8/D1
  resolved view feeds pusher+pie+export (e426b7b; resolvedSessions/
  resolvedContribution; ResolvedPostingChecks pins criterion 1); F23
  keep-all-fragments split (1955ffc); F21/D0.1 + F22/D0.2 anti-entropy +
  ≤200 chunked push (1955ffc; criterion-13 failure clause f02a47a);
  F19/D5 permanent-vs-transient + .stuck/.skipped (1955ffc); F12/D3
  .inflight verify-then-adopt (1955ffc) + F13 resurrection re-post (3e8be92);
  F11/D4 amendment loop update/delete+recreate/retract/.diverged (detection
  f3c0ac8, amendment 367910f) + D4b invoice-lock (685afb2); F18/D6
  finance-mapping store + Settings editor (a277f29, d1e0150); D2(a)
  posting-owner gate (8d869f1). D2(a) single-homing is what de-facto closes
  F9's double-post today. GENUINELY OPEN items broken out below.
- [ ] D2(b): synced posting ledger — own CloudKit record type keyed
  (sessionID, backendID), state-lattice merge (posted>skipped>failed>pending).
  Ledger is still local-only; this is what makes owner HANDOFF safe and shows
  posted state on every device. Needs a design session on the CK record type;
  blocks with CloudKit GA.
- [ ] D2(c): kill in-record posting bookkeeping when sync is on (fixes F10) —
  markPushed still writes pushedToOP/opTimeEntryID into the synced session, so
  bookkeeping still competes with edits in whole-record LWW. Depends on D2(b)
  carrying the state. F10 stays genuinely open until this lands.
- [ ] D0.3: surface decode drops — "N sessions from a newer andeye version
  aren't visible on this device" instead of silently compactMap-dropping in
  pull. User-facing; not built (deliberately deferred, per the D0 audit above).
- [ ] D7 / F14: billing.json is per-device — fold billable rules into synced
  settings when settings-sync lands. Deferred by design (D2(a) ownership bounds
  the harm to one evaluating device); until then, set billable flags on the
  posting owner.
- [x] Wire Settings surfacing — DONE 2026-07-08 (overnight): Posting health
  section (stuck + Retry, diverged counts); permanentlySkipped surfaces via
  lastError. REMAINING: entitlement-denial copy — lands with the cross-repo
  `requires:` seam change (gate is dormant until then).
- [ ] Pro repo: thread `XeroConnector.entitlement` through the seam once
  `register(..., requires:)` exists on BackendRegistrar (coordinated
  cross-repo change; main side already has the gated registry method).

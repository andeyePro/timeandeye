# Changelog

## 2026-07-12

- [x] **Closed the posting state machine's three user-path holes – timeline
  edits now honour invoice locks, failed retractions retry instead of
  orphaning, and deleting a session retracts its finance money too.** Behaviour
  changes first: (i) the invoice-lock law now covers every mutation path, not
  just bulk refile – a task-change timeline edit, `deleteTimelineSession`,
  `reassignTimelineSessions`, `coalesceAdjacent` (absorbed originals AND the
  survivor's in-place PATCH), and `applyReconcile` all consult
  `lockedInvoiceRef` before touching a remote entry. A locked cell's billed
  entry is never deleted or amended; the local edit still stands (the user's
  word) and the cell parks `.diverged`, surfaced on posting-health for a human
  to reconcile at invoicing time. (ii) A severed linkage whose immediate remote
  delete FAILS no longer clears its ledger row and orphans a live backend entry
  – the row survives `.failed` with the entryID retained under a retract
  intent, and the engine's next pass completes the retraction (then re-posts
  under the new task if the session still wants one), retrying until it lands.
  (iii) Deleting a session now retracts its finance entries as well as pm:
  unlocked finance rows are handed to the engine's retraction sweep, locked
  ones park `.diverged` – billed time never quietly outlives its session.
  Engine mechanics: `amendDiverged` gained a retract-intent sweep over
  `.failed` rows marked with `PostingSever.retractIntentReason` (kept distinct
  from the resurrection demote's same-state re-POST intent by the reason
  string, never the bare state), the create queue skips a session whose
  retract is still pending so no rival entry is made over an un-retracted
  linkage, and the pass re-asserts the legacy pm mirror from the primary-pm
  cell when a best-effort `markPushed` dropped it (M5 second clause). The law
  itself is pinned in Core (`PostingSever.plan`); the controller's application
  of it is the @MainActor half. `PostingMachineChecks` gained M2/M3/M4 and the
  M5 second-clause scenarios (886 → 893). Contract:
  `docs/superpowers/specs/2026-07-12-posting-state-machine.md`.

- [x] **Made the attribution engine conform to the certainty calculus – one
  number, one set of rules.** Behaviour changes first: (i) a human correction
  now marks its slice with the human-word certainty (1.0), so it becomes
  push-eligible at once – a timeline reassign (task-change edit and
  `reassignTimelineSessions`) and an Unknown-sweep repoint previously kept the
  slice's OLD engine-derived number, leaving a corrected slice stuck below the
  push bar; both now write 1.0 exactly as review-confirm already did (undo
  restores the exact prior number – `UnknownRepoint` gained a `priorCertainty`).
  (ii) The retro-lift eligibility gate gained `!pushedToOP`: the retro pass no
  longer re-scores an already-posted session (it shares the one
  `RetroEligibility` predicate with the review walk and the Unknown sweep now,
  so the three cannot drift). (iii) Fold unification – the two stray many-to-one
  certainty folds now match the flush: `JournalPrune`'s rollup (was max) and
  `TimelineMath.mergeAdjacent` (was min) both blend by the DURATION-WEIGHTED
  MEAN, so a long confident slice is neither dragged down nor oversold by a
  brief uncertain one. Non-behavioural conformance and hygiene: the ranked cap
  is now a named `rankedCeiling` (0.9) beside `inferredCeiling`, with a `0`
  FLOOR clamp so the others'-task −10 ranking penalty can never journal a
  negative certainty; the primed-surface and pending-prime scores, the tracker
  switch bar / idle-resume bar, and the duplicated calendar weights are all
  named constants referenced from one home (the timeline's span opacity now
  reads the tracker's `switchBar`); `reviewBelow` no longer carries an
  independent 0.9 – it defaults to the push bar's own default. New
  `CertaintyCalculusChecks` pins the seven invariants (tier ceilings, floor,
  human word, ownership, fold, one gate, ordering) as properties, not examples.
  Contract: `docs/superpowers/specs/2026-07-12-attribution-calculus.md`.
- [x] **Sealed the package's public API to a three-tier contract ahead of the
  public release.** Almost every cross-module type was `public` only because a
  sibling target in the same package read it – indistinguishable, from outside,
  from the handful of symbols a genuinely separate package links against. Using
  Swift `package` access (tools 5.10), the public surface now shrinks to exactly:
  (i) the `timeandeyeCore` connector seam (`TaskBackend`, `HTTPTransport`,
  `BackendPageRecognizer`/`NoPageRecognizer`, `BackendRegistry`, `BackendClass`,
  `BackendEntitlementRequirement`, `FinanceMapping`/`FinanceMappingStore`,
  `SyncEngine`, `WorkTask`, `TaskRef`, `RemoteTimeEntry`/`RemoteEntryID`,
  `TimeActivity`, `AmendmentError`, `PermanentPostError`) plus its signature
  closure; (ii) the licence/entitlement family (`License*`, `EntitlementDecision`,
  `EntitlementDenialReason`, `AndeyeScenes`), kept public per their cross-repo doc
  contracts; and (iii) the iOS companion surface (`PhoneController` and the Core
  logic/value types the iOS sources drive, including `AppSupport.directory()`
  reached through `PhoneController.init`'s default argument). Everything else in
  `timeandeyeCore`, `timeandeyeStore`, `timeandeyePhone`, `timeandeyeMac` and
  `timeandeyeTheme` demoted `public` → `package` – ~1,370 declarations, including
  `AppController`'s entire ~175-member UI-facing surface (its type stays public
  only because `AndeyeScenes.body(controller:)` names it), the InMemory* test
  doubles, the public `Array`/`NSColor` extensions, `DebugLog`, `EmailSignalProbe`,
  and the settings knobs bag (only `opBaseURL` and `taskColours` stay public, for
  the phone UI). `timeandeyeUI` was already sealed behind `AndeyeScenes`. No renames –
  access levels only. New spec: `docs/superpowers/specs/2026-07-12-public-api-surface.md`
  (the contract, the `package`-by-default rule, and a `TaskBackend` extension how-to).
- [x] **Removed the write-only `ContradictionRefile.Finding.priorProvenance`
  field.** The field, its `init` parameter and `plan()`'s capture of it had zero
  readers (the undo payload's provenance is snapshotted onto
  `RetroDigest.PriorSessionState` instead); dropped it and the write-only uses in
  `ContradictionRefileChecks`. `plan()`/`apply()` behaviour unchanged.
- [x] **The greyed Pro-connector row sources its denial reason from the
  entitlement seam.** `SettingsView` replaced a bare `license == nil` test with
  `BackendRegistry.entitlement(license:requires:)`, mapping each
  `EntitlementDenialReason` (`noLicense`, `notInConnectors`, `tierBelowFloor`) to
  its own accurate one-liner – which is what the decision type's doc comment says
  it exists to drive. Section layout and string tone unchanged.

- [x] **The contradiction pass fetches spans once instead of N+1 SELECTs on the
  MainActor.** Scoring each scanned session called `dominantSpan(of:)`, and that
  ran a fresh uncached `journal.spans(from:to:)` SELECT per session – up to
  `contradictionScanCap` (300) sequential synchronous main-actor queries every
  pass, ~2 s after a cold launch and after each teach burst. `runContradictionPass`
  now issues ONE `journal.spans` query spanning the earliest scanned session start
  to the latest end (so every session's [start, end] window is fully covered), and
  the scoring closure buckets that slice per session in memory via a new
  `dominantSpan(of:among:)`. The span-selection rule – longest FULL-span duration
  wins, a duration tie keeps the earliest start, overlap is `end > from && start <
  to` – moved once into a pure `FocusSpan.dominant(among:from:to:)` in
  `timeandeyeCore`; the fetching `dominantSpan(of:)` now delegates to it, so its
  other callers (`teachAssociation`, `markSessionDoNotTrack`) keep their exact
  behaviour. Because the wide fetch stays `ORDER BY start` and the per-session
  filter preserves that order, the bucketed winner is identical to the old
  per-session fetch. Over a 14-day horizon spans number in the low thousands
  (one closes per surface switch), so a single materialised array is cheap – no
  chunking needed. New `DominantSpan` check suite pins the selection rule
  (longest wins, earliest-start tie, full-span-not-clipped, overlap exclusion,
  bucket-equals-narrow-fetch). Scope: the span-fetch path only; scoring, `plan()`
  and the completeness guard are untouched.

- [x] **The cold-start contradiction pass no longer races the OpenProject
  fetch.** At launch `startUp` fires `refreshTasks()` unawaited and schedules
  the contradiction pass on a fixed 2 s debounce. On a fetch slower than 2 s the
  pass ran against a cache still seeded locals-only (the fetched OP tasks had not
  landed), and nothing re-ran it once they did – the `taskCache` didSet only
  invalidates the pick list. Two failures followed: a session whose incumbent OP
  task was absent from the shrunken candidate set could have a local rival
  renormalise over the auto-push bar, and with `.auto` refile mode that severed
  the unpushed OP linkage and silently withdrew the slice from posting. Two
  layers close it. Layer 1 – re-trigger: `refreshTasks` now calls
  `scheduleRetroPass()` on its success path, after `taskCache` is replaced with
  the full fetched-plus-local set; the same 2 s debounce coalesces with the
  startup timer on a fast fetch and re-runs the pass with the complete cache on a
  slow one. The startup kick stays, so pure-local users (who never reach the
  fetch success path) are unaffected. Layer 2 – completeness guard:
  `runContradictionPass` now skips any session whose current task is not
  resolvable in the captured cache (a single set lookup per session, at the
  scan/filter stage so `ContradictionRefile.plan` stays pure), because the pass
  cannot honestly judge contradiction when the incumbent candidate is missing;
  those self-correct on the re-triggered pass. Unknown-task sessions are exempt –
  the sentinel is never a scored candidate, so a confident real answer
  legitimately contradicts it and there is no shrunken-set distortion. Scope:
  startUp/refreshTasks/runContradictionPass plumbing only; the billable paths,
  refile guard internals and review threshold are untouched. No new Core
  behaviour to pin – both layers are AppController plumbing not reachable from
  `timeandeyeChecks`; `ContradictionRefile.plan`'s lane semantics remain pinned
  by the existing contradiction-refile checks, which the guard leaves unchanged.

- [x] **The billable widen gestures now get a real ⌘Z window.** Commit 860a137
  gave a bare entry mark an undo window by debouncing its finance sync 4 s, but
  the widen gestures – "mark this entry AND its task/project billable" – still
  posted instantly. They call `setSessionBillable(override:true)` (debounced)
  and then `setTaskBillable`/`setProjectBillable`, and those two flag setters
  fired an UNdebounced `Task { await syncIfEnabled() }`. That immediate sync saw
  the just-set entry override – which `Billing.financeEligible` honours with no
  `since` gate – and posted the clicked slice to finance within milliseconds; a
  ⌘Z a second later restored the flags but the entry was already on the client's
  books. Both flag setters now route their sync kick through the existing
  `scheduleBillableSync()` debounce, so every billable-mark gesture clears the
  same undo window before anything reaches the wire. Scope: this closes the
  zero-length undo window; it does not add claw-back – a mark left to stand, or
  undone after the debounce fires, still posts and stays posted (finance history
  is never retracted, by policy). The since-gate that stops a bare task/project
  flip posting pre-existing history was already correct and is unchanged. No new
  Core behaviour to pin (the fix is AppController timer plumbing, not reachable
  from timeandeyeChecks); the since-gate and the deferred-kick model are already
  pinned by the existing "flips are prospective-only" and "billable mark then
  immediate undo" checks.

- [x] **Bulk refile can no longer delete invoice-locked time.** The
  contradiction pass routed a posted slice to an actionable lane whenever its
  provenance was unstamped (rows journalled before provenance) or its score sat
  below the auto-push bar – from there "Refile all" severed the ledger row
  carrying the invoice lock and deleted the billed backend entry, with no lock
  consultation on the direct path. `ContradictionRefile.plan` now flags every
  posted slice regardless of score or provenance, so money never moves off a
  bulk pass; deliberate per-slice moves stay on the timeline-edit path. As
  defence in depth `applyRefiles` consults the posting ledger before acting and
  skips any invoice-locked slice whole – no journal write, no ledger clear, no
  remote delete – counting it onto the Posting-health surface. New
  ContradictionRefile checks pin the plan lanes across the posted × score ×
  provenance matrix.

- [x] **Restore the local-state ignore rules.** `.gitignore` again excludes
  
  
  binaries, so a routine broad `git add` cannot stage per-machine or working
  material. 

- [x] **install-timeandeye.command no longer self-clobbers on a loose .app
  source.** The self-clobber guard compared `$NEW` and `$DEST` as raw
  strings, so any textually-different spelling of the same installed bundle
  – a trailing slash from tab completion, a symlinked `~/Applications`, an
  absolute `/Users/<name>/Applications` path – passed the guard, `rm -rf
  "$DEST"` deleted the bundle, and `ditto "$NEW" "$DEST"` then read from the
  just-deleted source and aborted under `set -e`, leaving no installed app
  at all. Both sides are now canonicalised with a portable `cd`-and-`pwd -P`
  helper before the compare, so equivalent spellings resolve to the same
  path and the guard correctly treats them as identical; an unresolvable
  `$DEST` (fresh install, nothing there yet) is treated as "different" so
  the install proceeds as before. The canon helper is written to always
  exit 0 even when `cd` fails, since a failing command-substitution
  assignment would otherwise abort the whole script under `set -e` right
  when `$DEST` doesn't exist yet – the exact fresh-install case the fix
  needs to keep working. Verified with `bash -n`, a shellcheck diff against
  HEAD (no new warnings), and a sandbox harness exercising the extracted
  canon+guard logic against trailing-slash, symlinked-parent, genuinely-
  different, and missing-`$DEST` path shapes.

- [x] **Refile-batch digest now names its dominant target;
  `reviewThreshold`'s write-only remnant is gone.** Two independent
  2026-07-12 review findings, one commit. (1) `applyRefiles`'s digest
  stamped `target: .task(findings[0].newTask)` – the first finding's
  target – even though `ContradictionRefile.plan` derives each finding's
  `newTask` independently, so a mixed-target bulk refile rendered "Cleared
  N to \<firstTarget\>" in ReviewView's Recently-cleared row, hiding
  sessions actually refiled elsewhere. The sibling `applyRetroPlan`'s
  `dominantRetroTarget(in:)` already solved this for retro clearances –
  its "most-common, ties keep first seen" core is now factored onto a
  shared `[Target]` overload, with the existing `[RetroClearance]` entry
  point delegating to it and `applyRefiles` mapping each *applied*
  finding's `newTask` to `.task(...)` before delegating too, so the digest
  reflects only the sessions actually moved – not ones skipped for an
  invoice lock. Undo payloads stay per-session and untouched. (2)
  `AndeyeSettings.reviewThreshold` was write-only dead state since the
  2026-07-11 ONE-threshold change hardcoded `AppController`'s only reader
  (`uncertainBelow`) to a fixed `0.6` and removed the slider/IA entry, but
  the field, its doc comment (which still falsely called it a live
  UI-visible threshold), init parameter/default, memberwise assign and
  lenient-decode line all lingered. All five are now removed; a repo-wide
  grep (and a check of the mounted `andeyePro` reference tree) turns up
  zero remaining readers. Decode safety: `AndeyeSettings.init(from:)`
  decodes via `decoder.container(keyedBy: CodingKeys.self)`, and
  `CodingKeys` is auto-synthesized from the struct's stored properties (no
  explicit enum in this file) – with the property gone, `CodingKeys` has
  no `reviewThreshold` case, so the decoder never looks the key up; a
  leftover `"reviewThreshold"` in an old persisted settings file is simply
  an unrecognised key to a keyed container and is ignored like any other.
  No check ever read the field, so the suite count is unchanged. Bridge
  suite: 865 passed, 0 failed, before and after.

- [x] **Duration captions unified; slice-detail and sync gaps after a review
  confirm closed.** Three small correctness fixes from the 2026-07-12 review.
  (1) Two caption sites did their own duration maths that disagreed with the
  menu-bar clock: the Evidence Card's window chip rounded minutes with no hours
  bracket (a 2 h 05 m window read "125m"), and the timeline strip tooltip
  truncated with no hours bracket (a 90 s span read "1m" where the card said
  "2m"). Both now route through `MenuTitle.text(elapsed:certainty:showPercent:)`
  – the same formatter the today/tracked/selected/spent captions already use –
  so seconds/minutes/hours read identically everywhere. No new entry point, so
  the existing MenuTitle bracket checks still cover it; suite count unchanged.
  (2) `persistAssociations` cleared the pick-list cache after a grain "Remember"
  but never the slice-detail memo, so an open review disclosure kept showing
  pre-rule certainty – self-healing on the next retro pass, but sticking
  indefinitely when a high auto-push threshold disables that pass. The two
  invalidation lines `reloadReview` already ran are now a private
  `invalidateSliceDetails()` called from both paths, so the caches can't drift
  again. (3) `confirmViewedSlices` stamped confirmed sessions push-eligible but,
  unlike the live-assign paths, never kicked sync – the stamped time waited for
  the 60 s retry timer. It now fires one `syncIfEnabled()` after the confirm
  loop, only when at least one session was actually stamped. Scope: the two UI
  caption sites and AppController plumbing; no public API renames, no changes to
  the contradiction pass, billable setters or Settings. Bridge suite 865/0
  before and after; release `timeandeyeApp` build clean.

## 2026-07-11

- [x] **Undo: inverses run in order; groups don't swallow strangers.** (F3-3) `undo()` fired each inverse as a detached Task, so rapid ⌘Z⌘Z interleaved their awaits and inverse N+1's writes could race N's (last-writer-wins on the same rows). Inverses now chain — inverse N completes before N+1 starts — off the caller so the UI never blocks. (F3-4) `UndoStack.group` bodies that await yield the main actor, and any UNRELATED registration that interleaved during the suspension folded into the open group (one ⌘Z then reverted a stranger's edit under the wrong label). A task-local group token now scopes the fold to the group's own call context; a stray registration lands as its own ⌘Z step. New interleave check drives a group parked mid-await while an out-of-context registration arrives. (F3-7) `applyReconcile`'s per-id delete swallowed backend failures with `try?`, then undo unconditionally recreated every entry — manufacturing a duplicate for any delete that hadn't actually landed. It now tracks which deletes succeeded, undo recreates only those, and a failed delete surfaces via `lastError`. Suite 864/0; release `timeandeyeApp` build clean.
- [x] **Windows: activation targets the right Time window; green button survives transitions; re-front calms down.** (F1-1/F1-5) The two Time scenes both set their host NSWindow's identifier to the VIEW mode ("timeline"/"spent"), so `activateOnceVisible(opened: "time2")` could not tell the primary and second windows apart and fronted whichever came first; and `openGrantApplies` cross-granted "time"↔"time2" so opening one dropped the sibling into the auxiliary overlay pose (dead green button) for 4 s. Each Time window now carries its stable SCENE id ("time"/"time2") — the title still carries the view mode for the scroll-pan monitor — and the open grant is a plain identity match. (F1-2) `GreenButtonHelper.greenClicked` mutated collectionBehavior/level and toggled fullscreen with no transition guard, so an Esc-then-green mid exit-animation could wedge the window; it now holds off while a fullscreen enter/exit is animating, exactly as the 1 Hz timer path does (shared `isMidFullscreenTransition`). (F1-4) The 1 Hz re-front `orderFrontRegardless`'d AND logged every second while a visible window reported off-Space; it now retries a few times per off-Space episode then backs off to once per 10 s, and logs only when the state first appears. DebugLog gained an 8 MB size cap (atomic rename to `.old`, crash-safe). Suite 863/0; release `timeandeyeApp` build clean.
- [x] **Attribution: live decay actually decays; provenance stamps tell the truth.** Three correctness fixes to how a running clock and undo shape provenance. (1) The live-adjacency 30 s→15 min decay was DEAD: `handleFocus` runs `handleInput(now)`, whose `defer` bumps `lastInput` to `now` BEFORE `attribute()` reads `liveContinuity`, so the gap was always 0 and the running task took a FULL boost however long the user had been away (this shaped journalled certainty and auto-push). `handleFocus` now captures the previous input moment and passes it as `liveContinuity(at:lastActive:)`, so the boost decays over real inactivity; the reevaluate/enrichment paths keep the genuine `lastInput`. The existing LiveAdjacencyChecks fed synthetic `Continuity` values and were blind to this — added an integration-shaped check that drives `SessionTracker` end-to-end and asserts a 9-min gap boosts less than a 5-s one. (2) Undo of a task-change timeline edit re-stamped `.userAssigned` over the restored row's original provenance (`applyTimelineEdit`'s inverse re-runs the edit, which re-stamps on a task change) — it now puts the pre-edit provenance back, mirroring `reassignTimelineSessions`' undo. (3) The non-work→leisure flip in `SessionTracker.commitSwitch` never updated `currentDecision`, so leisure spans inherited the prior work task's provenance (incl. `userAssigned`) — it now stamps an honest engine decision (`.ranked`) for the leisure target. Suite 863/0; release `timeandeyeApp` build clean.
- [x] **Docs: manual Billable exception, moved-file citations, and hero copy "time donut" wording** — MANUAL.md and time-window.md now note the live/running slice has no Billable menu; assets/brand/README.md and the site previews cite AndeyeLogo.swift's actual location (Sources/timeandeyeTheme/); marketing copy says "time donut" throughout, matching the app.
- [x] **Polish: stale strings, search-index truth, and small UI
  correctness fixes from the mechanical review cluster.** SettingsIA's ⌘F
  index still spoke old control names: "Time button opens" → "Donut button
  opens", "Quiet while presenting" → "Hide banners while presenting", "Lock
  the Mac when I leave my desk" → "Lock the Mac when I continue work away"
  (matching the actual walk-figure toggle label) — old wording kept as
  keywords so existing muscle memory still finds them, and "donut" added to
  the two Time Donut legend link items (manual colours, currency). The
  timeline's Move-bar blue-suggestion gate read `settings.reviewThreshold`,
  whose Settings UI was deleted; it now reads `certaintyAutoPushThreshold`
  (the setting itself stays decodable for old settings files — no other live
  read of `reviewThreshold` remains). The Local tasks project field's binding
  returned "Personal" for a nil project via `projectName`, so the field could
  never be empty and the greyed "Personal" prompt never showed — it now
  returns the raw optional as "", restoring the prompt (typing "Personal"
  still collapses back to nil; the greyed/plain display split is untouched).
  The email-order caption stated the fixed specificity ladder unconditionally
  even though old settings files' custom `emailMatchOrder` is still honoured
  internally — it now says so only when the stored order differs from
  `EmailMatchLevel.defaultOrder`. iOS `NowView`'s "Time pie" accessibility
  label and the menu-bar donut's tooltip lead word ("Time" → "Donut") now
  match both manuals' naming. Comment-only sweep: eight comments across
  `SessionTracker`, `Settings`, `AppController` and `TimelineView` still
  quoted the dead "Change to" control name — updated to "Reassign". Suite
  862/0; release `timeandeyeApp` build clean.
- [x] **Sync: close the requarantine double-post race with an atomic
  conditional ledger write.** `SyncEngine.requarantine` (the retry-stuck ⌘Z)
  read the posting record, then — in a SEPARATE store call — wrote the stale
  `.stuck` snapshot back unless the read showed `.posted`/`.inflight`. Because
  `SyncEngine` is a plain class, its async posting pass runs OFF the main
  actor while the synchronous requarantine runs ON it, so the freed retry
  could write `.inflight` in the gap between that read and write — the stale
  `.stuck` then clobbered the in-flight create, hiding it, and a later pass
  re-posted the same time (duplicate backend entry). New `JournalStore`
  primitive `setPostingRecord(_:unlessState:)` does the state check and the
  write in ONE critical section (the SQLite store holds its `NSRecursiveLock`
  across both; a non-atomic default covers the single-threaded in-memory
  store/mocks). requarantine now uses it, so a create already on the wire
  stays truthful and the reconcile sweep owns it — the undo is a no-op for
  that row rather than re-opening the F12 amnesia window. New ResolvedPosting
  check pins the primitive with the interleaving pre-applied. Suite 862/0.
- [x] **Billing: a mis-clicked billable mark now has a real undo window.** A
  timeline entry-mark bypasses the prospective-only `since` gate (marking the
  entry IS the consent), so it posts to the finance backend the moment a sync
  sees it — and posted history is never clawed back. But
  `setSessionBillable` awaited `syncIfEnabled()` INSIDE the gesture, so a mark
  posted before ⌘Z could ever fire: the undo window was structurally zero, and
  a mis-click stayed on the client's books. The sync kick is now debounced (a
  few seconds) so an immediate undo retracts the override before anything
  reaches the wire; the undo path defers its kick the same way. The widen-to-
  task and widen-to-project gestures route their entry-mark through the same
  method, so they are covered too. Design fact preserved: a mark left to stand
  past the window syncs on the next pass and, once it has synced, is still
  never clawed back — marking IS consent once it stands. New BillingChecks
  case pins mark → immediate undo → nothing posted, and mark-that-stands →
  posts → no claw-back. Suite 861/0.
- [x] **Refile: a posted slice re-filed under a new task now sheds its
  backend entry, and refile confidence no longer inherits the old task's.**
  `AppController.applyRefiles` re-pointed `session.task` with no backend
  hygiene — a posted slice reached the suggestion lane (below-bar contradiction
  or nil provenance) and, once refiled, its OpenProject/finance entry stayed
  filed under the OLD work package while the journal claimed the new one. It
  now runs the same delete-and-clear `applyTimelineEdit`/
  `reassignTimelineSessions` do: the old entry is deleted, the id/pushed flag
  cleared, and a deferred sync re-creates the entry under the new task. Undo
  restores the prior linkage STATE faithfully — a posted slice re-posts under
  the restored task (the dead id is never resurrected, matching the timeline
  edit's undo). The decision is factored into Core (`ContradictionRefile.apply`)
  so it is unit-pinned. Second bug in the same method: refile certainty was
  `max(session.certainty, finding.score)` — the old task's confidence inflated
  the new target; it is now the re-derived `finding.score`. `RetroDigest`'s
  undo payload gained `priorPushedToOP` (optional, lenient-decode). Three
  ContradictionRefile checks pin the certainty rule, the sever decision, and
  the posted-slice apply+undo round-trip. Suite 860/0.
- [x] **Housekeeping ahead of the public flip.** Internal working notes left
  the tracked tree, the multibackend billable spec now carries only its
  external cost citations, and earlier backlog notes about the tidy fold
  into this line.
- [x] **Tracking: gate the pending-switch revert, de-duplicate the reassign
  teach, show window duration, and tell the boost delta honestly.** Four
  fixes from Martin's 2026-07-11 logs. (1) The main bug: a pending switch
  reverted the instant the base task reappeared, with NO confidence gate —
  so a live-adjacency-boosted ~0.42 sighting of the base cancelled a
  0.95-confident switch (his 14:22:30–32 sequence). The revert now requires
  `best.score >= config.uncertainBelow` (the same 0.6 floor a forward switch
  needs); a genuinely confident (≥0.6) return still reverts. New
  `SessionTracker` check reproduces both arms using OP work-package pages
  (definitive 0.95 that teach the ranker nothing, so the base carries only
  its faint prior and wins solely on the boost). (2) A reassign taught the
  attributor twice — `SessionTracker.relabelCurrentSession` called `confirm`
  (weight 2) on top of `AppController.changeCurrentTask`'s deliberate
  `assign`. Dropped the tracker-level teach (the controller is
  `relabelCurrentSession`'s only production caller and owns the single
  `assign`); the correction now lands once. (3) `EvidenceCardView.Recorded`
  gains `end: Date?` (populated from `spans[i].end`); the timeline card shows
  a quiet start–end · duration caption under the window name, omitted when
  there is no recorded span. (4) The adjacency reasoning said "+22%" for what
  is percentage POINTS; `AdjacencyBoost.apply` now formats it as
  "0.19 → 0.42 (+23 pts)" (drawer and live share the one path). Checks that
  pinned the old "+N%" reasoning updated to the honest form. Suite 857/0.
- [x] **Review: walk-through confirm — one click covers exactly the viewed
  slices (his respec).** No whole-day confirm anywhere, by design
  ("what if I only manage to review part of the day"). The drawer's new
  walk bar arrows the day's pending slices chronologically in EITHER
  direction (⌘[/⌘], bare ←/→ while the list has focus): every slice landed
  on opens its full detail and is marked viewed (eye mark; per-group k/n
  tallies); clicking a slice or opening its disclosure marks it too, while
  Expand all and mere scrolling deliberately never do — rendering is not
  viewing. **Confirm viewed** then takes the engine's current read of each
  viewed slice (`attributor.explain` at the slice's own moment — the same
  numbers its detail showed) as the user's word: per-target batches through
  the existing `assignReview` teach path, overlapping unpushed below-bar
  sessions stamped `userAssigned` (detail "confirmed in review") at full
  certainty — the EXISTING user's-word state, so `ContradictionRefile`
  never refiles/nags them and the retro lift never touches them again —
  all as ONE ⌘Z (`UndoStack.groupSync`, the AI-apply shape). Viewed slices
  the scorer has nothing for stay queued (no word to take); slices acted
  on mid-walk count handled, not viewed; the cursor relocates to the
  nearest survivor after an assign, and an arrow never skips an unviewed
  slice under the cursor. Pure core first: `ReviewWalk` (order/cursor/
  viewed, prune-and-relocate) + `ReviewConfirm` (plan: per-target grouping,
  unresolved, session stamps with prior-state undo payloads) in
  `ReviewWalk.swift`, 20 new checks including the userDecided-set contract
  pin. Viewed state lives on the controller for the app run — survives
  closing/reopening the window, resets on relaunch (simple honest option;
  attention is never journalled). Both manuals updated. Suite 856/0;
  release `timeandeyeApp` build green.

- [x] **Sync: criterion 13's failure clause pinned (D0 audit).** The
  multi-device spec's D0.1/D0.2 (F21 re-assert local wins, F22 batched
  pushes) turned out already built and verified in the licence/sync batch;
  auditing the spec's acceptance criteria found one unpinned clause — a
  mid-backlog batch failure must leave the failed chunk (and the
  un-attempted tail) dirty for retry while the landed chunk stays clear.
  New `FlakySyncServer` + JournalSyncer check: batch 2 of 3 rejected → the
  cycle surfaces the error, exactly 200 records reach the server, 250 rows
  stay dirty; the recovery cycle uploads only the missing 250 (no
  re-upload, no loss). Suite 836/0 on the Mac. D0.3 (surfacing decode
  drops) stays open.

- [x] **Timeline: per-entry billable marks (his Currency review).**
  Right-click a timeline slice → Billable to mark JUST that entry billable
  or non-billable: `Session.billableOverride`, journalled on the row itself
  with the SessionProvenance lenient-decode pattern (old journals load, nil
  = inherit), beating the task tri-state and project flag in BOTH
  directions; absence inherits exactly as before
  (`BillableRules.effectiveBillable(entryOverride:)`). The same menu widens
  the mark — "Billable: whole task/project" stamps the entry AND flips the
  existing task/project flag in one ⌘Z step; the entry stamp is what makes
  the clicked slice itself invoiceable, since flag flips stay
  prospective-only. Entry marks are finance-eligible with no `since` gate
  (marking the entry IS the consent the gate collects for flips) and are
  excluded from the stranded-time arithmetic (their posting is their own
  mark's business). Per-entry marks flow to finance posting via the sync
  closure; the slice editor's footer shows the entry's billable state; the
  flip alert copy is now shared with the pie legend (`billableFlipMessage`).
  4 new checks: both-direction precedence, no-since-gate +
  personal-always-wins, old-JSON/junk decode, stranded arithmetic.
  Suite 835/0.

- [x] **Menu bar: draw-in certainty + monochrome.** Two new
  Menu bar toggles, both default-off. *Draw in certainty* strokes the &I
  mark in proportion to the live attribution certainty, revealed EYE-first
  per Martin's ask — the reveal parameterisation gained a direction
  (`AndeyeLogo.stroke(t:wink:from:)`: `.tail` is the original draw-on,
  every existing call site unchanged; `.eye` is a trailing-arc-length
  reveal that pins the mark's closing point and grows the front backwards
  through the flourish), with `drawInReveal(certainty:)` mapping certainty
  onto `eyeFraction + c·(1−eyeFraction)` so the eye is always whole, every
  sub-1 certainty is visibly partial, and nil (stopped) shows the full
  mark. The controller's `logoT` still owns the draw-on/wink animations
  and scales the certainty target, so the startup hand-draw and the
  task-switch wink survive unchanged. *Monochrome* renders the whole
  status item as a template image (drawn black, macOS supplies the tint
  like its own items): colour signalling is inherently suppressed, and
  the calendar alerts blink the mark's ALPHA instead of the amber tint so
  a meeting alert still alerts. Both compose. Lenient-decode settings
  fields, ⌘F rows, 9 new checks (8 eye-reveal geometry + IA search) plus
  extended settings default/old-JSON/round-trip checks. Suite 831/0.

- [x] **Palettes — colour sets renamed, generic form added.**
  User-facing "colour set" became "palette" everywhere (Settings section,
  buttons, ⌘F rows, manuals); `ColourSet` grew into `Palette` (typealias
  kept) with TWO forms in ONE file format. Full = the old shape verbatim
  (same coding keys both ways, old files load, new full files open in old
  builds; literal-fixture check proves the on-disk contract). Generic =
  ordered colours only, no task/project names: loading seeds the automatic
  pool via `rederiveAll(paletteColours:)` — colour i becomes project i's
  anchor in first-seen order (swatch hex verbatim, its OKLCH hue the
  family's neighbourhood; achromatic seeds keep the swatch but let the
  engine pick the hue; projects past the palette's end allocate normally,
  spread away from the seeds), user picks untouched and still steering
  their family, one ⌘Z restores. "Save generic palette…" derives the file
  from the current effective project colours in first-seen order. 12 new
  checks (ColourPalette + a SettingsIA rename/rank check).

- [x] **Connections redesigned — licence first, classed twisties.**
  Licence moved from About to the top of Connections (it is what unlocks
  connectors, so it lives with them; the search index follows). Connectors
  group under Standard / Pro / Premium subdividers; each connector folds
  its plumbing (URL, key, connect, connected-as, default activity) behind
  a twisty whose heading shows the at-a-glance truth ("OpenProject — 143
  tasks · name") and opens itself only while unconnected. Posting health
  renders under its connector but never inside the fold — a problem must
  not hide behind a twisty. Xero sits greyed behind the licence gate with
  an upgrade link in the community build and goes live when andeyePro
  registers it (new `registeredConnectorNames` API). Suite 810/0.

- [x] **Billing sidebar is now Currency; legend link in caption (
  "Billing is confusing — it normally means app billing").** Sidebar title
  and section header renamed (enum raw value untouched so the persisted
  selection survives — the Codable rename lesson); search keywords keep
  "billing" so old muscle memory still lands; the caption's "Time Spent
  legend" prose became a live Time Donut legend link. Billing mappings
  keeps its name — it really is billing. Suite 810/0.

- [x] **Posted-vs-tracked wording — name the app, link the flag.**
  Users can't be assumed to know "tracked" vs "posted": the review-floor
  caption now says brief visits still follow the Auto-push rule; the refile
  caption says "entries posted to OpenProject" (live backend name) and
  "flagged" is a real link that opens the timeline; the Posting-health
  banner names the connected app and "review them on the timeline" is a
  link, not prose. Suite 810/0.

- [x] **Typeable number beside every slider/stepper.** Every
  numeric control in Settings pairs with a right-aligned number field
  bound to the same value, clamped to the control's range: auto-push
  threshold (%), review queue floor (s), switch buffer (s), sleep grace
  (s), idle backfill window (h), menu-bar task chars. Hard cap (MB) and
  consolidate-years were already typeable fields. Suite 810/0.

- [x] **Local tasks rebuilt clean (his xnip — "ugliest thing in the
  whole app").** Root cause from the screenshot: TITLED TextFields inside
  a grouped macOS Form render their titles as row labels (the ghost
  "name" / duplicated "Personal" captions over right-aligned boxes), and a
  width-clipped ColorPicker overlapped the field. Rows now use a
  natural-size swatch, borderless plain fields with prompts (project greys
  when inherited), a quiet trailing trash, and a plain Add row; the
  section header carries the never-sent promise; caption tightened and
  speaks Donut.

- [x] **ONE threshold — the review threshold is deleted (his mandate).**
  The silent limbo is gone: slices between the review threshold and the
  push bar were journalled but never asked about and never posted. Now the
  auto-push bar IS the review gate — everything below it queues (the
  review floor still keeps brief visits quiet), everything at/above it
  posts. TrackerConfig splits the old dual-role `uncertainBelow`:
  switching keeps a fixed internal 0.6 floor; a new `reviewBelow` follows
  the push bar live (`setReviewBelow` on the slider's didSet — no
  relaunch). The slider is renamed "Auto-push to OpenProject" (live
  backend name); its search entry absorbs the deleted one;
  ContradictionRefile's suggestion floor becomes a fixed 0.5.
  `settings.reviewThreshold` stays decodable but feeds nothing.
  Suite 810/0.

- [x] **Email match order is fixed — reorder controls deleted (his
  mandate).** Neither of us could name a case where mail system < domain <
  correspondent < subject should run differently, so the up/down controls
  and their search entry are gone; the caption states the fixed ladder
  plainly. Old settings files' stored order stays honoured internally.
  Suite 810/0.

- [x] **The 314 wording/link cluster — Donut rename, presenting label,
  links not buttons.** Time Pie → Time Donut (window title, Donut-button
  picker, popover/timeline helps, Settings link); "Quiet while presenting"
  → "Hide banners while presenting"; Auto-comment lives under Comments;
  "disable colour signalling"; the meeting alert names what it does (pulse
  the menu-bar mark); lock-on-leave names the walk-figure control that
  arms it; the colours caption's buttons became inline links, and the
  review-floor caption hyperlinks Switch Buffer (jumps to Behaviour).

- [x] **Mis-filed slices get acted on (his design, approved).** The
  why-panel's "today's rules would say" line grew hands:
  `ContradictionRefile` (pure, 6 checks) re-derives recent slices against
  today's rules on the retro pass's debounce and, provenance-gated —
  user-decided slices are never touched — refiles ENGINE-decided slices
  automatically when contradicted at/above the auto-push bar (one
  RetroDigest = one undo, same "recently cleared" drawer section);
  already-POSTED contradictions are flagged in Posting health, never
  moved; below-bar or pre-provenance contradictions become one "N slices
  look mis-filed" review row with Refile-all / Dismiss (dismissals persist
  per slice+target in settings). The card itself gains "↪ refile as X"
  whenever its record contradicts today's confident answer. Plus
  diagnostics mode (Settings ▸ Diagnostics) gating the card's copy
  button, native green-button nuances restored, and the plain card layout
  back. Suite 810/0.

- [x] **Live-session batch (overnight, with Martin testing).** Evidence
  card: all facts render as ONE selectable text run (single click-drag
  copies the whole card; the interim copy button removed), `[+ all]` moved
  to the card's top-right (selects every same-data window in the slice;
  disabled-not-hidden with no twins), empty captured titles fall back to
  the tab's site host in the card header and strip chips. Fullscreen fix
  fourteen: no auxiliary re-grace after a fullscreen exit (it blocked an
  immediate re-green-button); the fix-thirteen transition hold stays.
  Settings gear opens first-click (activation now targets the requested
  window, not just the app). Timeline editor swatch shows "auto"/revert
  conditionally. Colours: re-derive and the new "Shade tasks around this"
  honour the user's project picks (`rederiveAll` anchor-hue overrides,
  check-covered); "Manually picked colours" manager with per-row revert +
  revert-all. Review-floor stepper bottoms at the Switch Buffer. ⌘Z
  explanations swept from all UI copy.

- [x] **Colours settings category — re-derive from scratch + colour sets.**
  preserved pre-engine task colours share no family (each was an
  independent hue), so Settings ▸ Colours now offers **Re-derive all
  automatic colours** — `ColourEngine.rederiveAll` drops and re-allocates
  every groupable record in first-seen order (anchors spread the wheel,
  tasks shade their project's ±25° neighbourhood; ungroupable history
  records and user overrides untouched; deterministic; one ⌘Z restores) —
  and **colour sets**: save/load the complete look (overrides + engine
  store) as JSON, load = one undo step. 5-check ColourRederive suite;
  manuals updated. Suite 803/0.

- [x] **Fullscreen fix thirteen — pose mutation held across enter/exit
  transitions.** A green-buttoned window came back from Esc frozen,
  unclickable and sinking behind other windows: .fullScreen leaves the
  styleMask before the exit animation completes, so the 1 Hz pose timer
  mutated collectionBehavior/level mid-animation — which wedges the
  window. SpaceJoiningView now brackets the will/did notifications and
  holds every mutation through the transition + 2 s settle, then
  re-decides from a fresh grace like a reopen.

- [x] **Evidence card + settings polish.** Whole-card
  copy button (drag-selection grabbed one line at a time); suppress-fallback
  control grey like its siblings; empty captured titles no longer render
  "App – "; timeline editor gains reset-colour-to-automatic and moves the
  close-✕ away from the swatch; unpin wears pin.slash; menu-bar colours use
  the stock picker (hex persists); Tracking leads the Settings sidebar and
  is the default panel; Backend → Connections; Tracking sliders named; ⌘F
  robustness (1×1 key-equivalent target) and a plain search placeholder.

## 2026-07-10

- [x] **timeandeyeTheme is now a leaf brand target.** `AndeyeLogo` (the
  mark's geometry, pure Foundation) moved from timeandeyeCore into
  timeandeyeTheme — the theme's only engine use — so sibling andeye apps
  wanting just the brand no longer drag the whole engine in.
  timeandeyeMac gained the theme dependency (AndeyeLogoImage renders the
  mark); AndeyeMark/checks/site literal-port comments repointed.
  Coordination note posted for sibling repos (import timeandeyeTheme, not
  timeandeyeCore, for AndeyeLogo). Suite 798/0; app build clean.

- [x] **Decision provenance journalled — BECAUSE names the original
  decider.** Follow-up to the why-panel truth fix: the journal now records
  WHICH source decided each slice (`SessionProvenance` on Session +
  FocusSpan — pin, sticky, backend URL/title, learned email/site rule with
  the matched value, prime, ranked with the live-adjacency reasoning,
  userAssigned, aiApplied, resumed, retro). The tracker carries the
  decision through uncertain holds and provisional switches (a reverted
  excursion restores the pre-pend story; an inferred agreement never
  overwrites "you assigned it"), and flush folds spans to the
  duration-dominant decider (pinned runs stay the user's attestation).
  Reassignments OVERWRITE (provenance = what stands; the displaced belief
  remains the card's history line) and every undo path restores the prior
  provenance (UnknownRepoint + RetroDigest.PriorSessionState extended,
  old digests still decode). Evidence Card: "this time stands as → X 82% —
  a learned rule fired (✉ client@…)"; the raw source is stored as a string
  so future renames can't wipe old journals (unknown values read "decided
  earlier"). 8-check Provenance suite; manuals updated. Suite 798/0.

- [x] **Live-attribution adjacency prior.** His decision ("the
  running timer IS a sound prior without outcome data"): while the clock
  runs on a task, that task's candidate for an ambiguous surface is lifted
  by the drawer's one-sided adjacency maths (`AdjacencyBoost.live`, same
  constants — 30% of the gap to the 0.95 ceiling, full ≤30s decaying to
  zero at 15min), fed from `SessionTracker.liveContinuity` (the COMMITTED
  slice's task during a provisional switch, never the display guess;
  stopped clocks carry no prior). Only the ranked fallback is touched —
  pins, stickies, backend URLs/titles and learned rules return before it.
  This deliberately shapes journalled certainty and auto-push, per his
  explicit call; every applied boost DebugLogs ("live-adjacency …") so the
  shared constants can be fitted from corrections (TODO). 9-check
  LiveAdjacency suite; manuals updated. Suite 790/0.

- [x] **Settings reorganised into categories with ⌘F search.** The single
  long scrolling form became a System-Settings-style split view: sidebar
  categories (Backend, Tracking, Behaviour, Menu bar, Local tasks, Billing,
  Email & Calendar, Maintenance, Diagnostics, About) with the section bodies
  moved verbatim; a search field above the sidebar (⌘F focuses it, Esc
  clears) finds any setting by visible label or synonym ("color", "xero",
  "csv") and jumps to its category. The index is a pure Core type
  (`SettingsIA`: categories + item registry + ranked
  case/diacritic-insensitive search, titles outrank keywords) proven by an
  11-check suite; conditional sections (Posting health, Billing mappings)
  stay indexed so search lands on the right category even while hidden.
  Manuals updated (site settings page restructured to the category IA;
  MANUAL.md lead-in). Approved at his. Suite 781/0.

- [x] **Why-panel truth: BECAUSE anchors on the recorded decision, never on
  a rule learned later.** Martin: "The BECAUSE 'remembered from a past
  correction → andeye Ltd confirmation statement + director ID verification'
  makes no sense to me as the window is in a slice categorised Time&I."
  Diagnosis: the timeline's Evidence Card re-ran `explain()` against the
  CURRENT stores — his correction on the Companies House email (made later,
  while handling that email) had primed its surface toward the CH task, and
  the card presented that as the reason a slice decided EARLIER was tracked
  there, though it never fired for it. Fixes: (1) the timeline card now
  receives the slice's journalled outcome; when the re-derivation contradicts
  it, BECAUSE reads "this time stands as → …" and the re-derivation is
  demoted to "today's rules would say: … – not what decided this slice"
  (`AttributionExplanation.contradicts(recorded:)`); (2) prime matches carry
  their matched key (`matchedSurface`) and the card shows it ("↺ remembered
  surface: …"), so over-broad learning is visible and the existing ✕ forget
  removes exactly it; (3) found en route: `explain()`/`forgettable()` were
  MUTATING — re-explaining an old slice at its own moment (review drawer,
  retro pass, timeline card) pruned TODAY's live stickies out of the store;
  reads now use a non-mutating sticky lookup, only `attribute()`/corrections
  prune. New `WhyPanelTruth` suite reproduces the report end-to-end; manual
  updated (both copies). Suite 770/0.

- [x] **Fullscreen fix twelve: the open-grace is scoped to the window being
  opened.** (Entry documents 6c044bb, which landed a minute before this
  line — a concurrent commit raced the changelog edit.) The fix-ten grant
  re-graced EVERY themed window on any open, holding them all in the
  auxiliary overlay pose for 4s — and auxiliary windows cannot enter their
  own fullscreen, so the green button worked or failed depending on
  whether anything had been opened in the previous few seconds. The grant
  now carries the opened scene's id and only the matching window restarts
  its grace; the review/settings/rules windows gained stable identifiers.

- [x] **Review drawer selection goes native: click replaces, ⌘-click
  toggles, ⇧-click spans; brighter accent highlight; bigger twisty
  targets.** Martin's follow-up on the morning's click-to-toggle model:
  "You appear to have moved to a darker and harder to discern blue than
  before. And you have used an unconventional and unintuitive selection
  criteria. Can we have the macOS default …? The twisty … is now much
  harder to successfully click." Three fixes, keeping everything he
  liked (mixed group+slice selections, aggregated assign-bar certainty,
  ⌫/⌘D/⌘E, lazy detail, assign-recalculates). (1) *Semantics*:
  `ReviewSelection` (Core) is now a value type carrying the selection
  plus the span anchor, speaking NSTableView: plain click REPLACES the
  selection with the clicked row (a stack's header/left margin = the
  whole group), ⌘-click toggles a row in/out (partial group completes;
  full group leaves whole), ⇧-click spans from the most recent non-shift
  click through the clicked row over the FLATTENED visible row order
  (`ReviewRow`: group rows and slices interleaved, so a span across
  headers takes the groups in between whole); successive shifts re-span
  from the same anchor over the selection that predated it; a vanished
  anchor degrades to a plain click. `ReviewRangeSelect` (the stack-id
  range helper it absorbed) is deleted. (2) *Tint*: the 0.22-opacity
  accent wash (murky on the drawer's dark background) is replaced by the
  solid `Color.accentColor` fill a native List row shows, with selected
  text going white (primary) / white-85 (secondary) so it stays legible.
  (3) *Twisty*: both disclosure chevrons get a 20×18pt hit target and sit
  OUTSIDE the row's selection click surface — opening never changes the
  selection. Checks rewritten to pin the native matrix (replace incl.
  re-click, group-as-row, ⌘ partial-completes/full-removes, span both
  directions + across headers, re-span, ⌘-moves-anchor/⇧-doesn't,
  degraded anchor, prune, clear, empty-stack no-op) and the sort-then-span
  backlog flow. Manual (site keyboard + attribution pages, MANUAL.md)
  rewritten to the Finder-familiar wording. Suite 765/0.

- [x] **Pie colour editing: legend swatches open a colour-editor popover
  (project + task), with reset-to-automatic and undo.** Martin, twice:
  "I can see no way of editing any colours in the pie" — the only
  editor was the timeline slice editor's ColorPicker. Now every legend
  swatch (project row and expanded task row) is a button: click it (or
  the row context menu's "Edit colour…") for a popover with the native
  picker, a "your pick / automatic" state line, and **Reset to
  automatic**. Task picks use the existing `settings.taskColours`
  override path; project picks get a parallel `settings.projectColours`
  override (stable project key → hex) that wins for display while the
  ColourEngine's anchor record stays byte-identical underneath — so the
  repair pass can never move a user's pick and reset always restores
  the exact automatic colour. A recoloured project steers FUTURE task
  shading (`ColourEngine.overrideAnchorHue` feeds `taskHex`'s new
  `anchorHueOverride`; achromatic/grey picks steer nothing — their hue
  is quantisation noise); already-seen task records never move. All
  four actions (set/reset × project/task) register with the app-wide
  ⌘Z; propagation is live everywhere colours render (settings is
  `@Published`; overrides never touch colours.json). Ring-3 window
  wedges remain derived from the task colour — per-window colour
  identity (pin-grain records) is still open in TODO, and wedge
  right-click editing is deferred with it. Checks: override steering +
  record immutability + reset fallback, achromatic-override guard,
  override-outranks-engine-post-repair (ColourEngineChecks). Manual
  (site time-window page + MANUAL.md) gains the one-line "click any
  legend swatch" instruction.

- [x] **Review drawer: instant expand-all, and click-to-select replaces
  the per-slice Assign button.** Martin's live feedback, two calls.
  (1) *Perf*: Expand all was "intolerably slow" — every open slice
  disclosure ran its own ±30-day journal range query plus a full ranker
  `explain`, synchronously, inside EVERY SwiftUI render pass (N open
  slices = N queries + N explains per keystroke). Opening structure is
  now free: slice rows render from the queue's own data, and the
  expensive detail (certainty build + neighbours) is computed lazily per
  visible disclosure by `AppController.requestSliceDetail` — requests
  from one render pass coalesce into ONE journal range query spanning
  the batch, partitioned in memory (`SliceNeighbours.batch`, the
  `adjacencyScores` shape), with the per-slice explains chunked between
  main-actor yields; results cache in `sliceDetails` (rows show
  "assessing…" for the beat until theirs lands) and invalidate by
  generation on every queue reload. (2) *Selection*: the per-slice
  **Assign…** button (shipped that morning; rejected — "makes no
  sense") is gone. Clicking a slice toggles its accent highlight;
  clicking a stack's header or the strip down its left margin toggles
  the whole group (`ReviewSelection`, Core-checked: group state IS
  per-slice membership, a partial group completes rather than clears);
  shift-clicking a header sweeps every group from the last header
  clicked (absorbing the 2026-07-09 stack-range sweep — the native
  List-selection ⌘-click/⇧↑⇧↓ went with the native selection it rode
  on). A selection freely mixes lone slices and whole groups; the
  assign bar acts on all of it, its button certainties the
  `AdjacencyBoost.aggregate` mean over EVERY selected slice; assigning
  removes exactly those slices, and the remaining groups and scores
  recalculate. ⌫/⌘D Clear, ⌘Z, ⌘E and the sort control unchanged.
  Manual (site + root) rewritten to the selection model.

- [x] **Fullscreen fix eleven: the green button makes a Time&I window
  fullscreen again.** The pose flags stripped .fullScreenPrimary
  unconditionally, so the green button could never create the window's
  own fullscreen Space — over another app's fullscreen it just zoomed
  the floating window across everything (Martin's afternoon report).
  Primary and auxiliary are exclusive: the desktop pose is now a normal
  primary-fullscreen-capable window (green button works), the
  fullscreen-capable pose stays an auxiliary overlay (green-buttoning
  WHILE floating over another app's fullscreen still cannot spawn a
  Space — an auxiliary-window constraint of macOS; leave the other
  app's fullscreen first). A window inside its own native fullscreen
  Space is now left entirely alone by the pose machinery.

- [x] **Fullscreen fix ten: opening a window you left on a desktop now
  surfaces it over a fullscreen app first click.** Martin's afternoon
  report: the popover icons needed several clicks over fullscreen
  Obsidian. The uncovered case: a window left OPEN on a desktop Space is
  visible and settled, so neither the hidden-window pose maintenance nor
  the show-transition grace protects it — and the popover blinds
  promotion at exactly click time. Every themed-window open (all sites
  funnel through the activation gate) now posts a synchronous open-grant;
  each window restarts its open grace and re-applies the
  fullscreen-capable pose in the click's own runloop turn, ahead of
  SwiftUI's deferred order-front where macOS decides the Space. Cost: the
  other themed windows float for the 4s grace too, then settle.

- [x] **Review drawer retest fixes: open-all, a findable per-slice Assign,
  pending-review neighbours, and "Do not track" becomes Clear.** Martin's
  live retest, four calls in one pass. (1) Header **Expand all / Collapse
  all** (⌘E) opens every stack AND every slice disclosure at once
  (Core-checked `everyStackID`/`everySliceID`/`isFullyExpanded`, subset
  semantics so assigned-away ids can't wedge the control). (2) The
  per-slice assign had shipped that morning but he couldn't find it: a
  lowercase borderless "assign" washed grey by the row's secondary
  foreground read as metadata — now a bordered mini **Assign…** button
  with its own tint on every slice row; a new aggregate check pins that
  assigning the odd slice away raises the remaining group's mean (the
  memo is keyed by segment-id set and cleared on every reload, so buttons
  recompute). (3) "Every item shows a gap": the neighbour arithmetic was
  exactly his spec (prev.end→start, end→next.start — confirmed), but the
  lookup consulted attributed sessions only, so a slice flush against
  ANOTHER pending slice reported a gap to some distant session. New
  pending-aware `SliceNeighbours.around(start:end:in:pending:)` picks the
  nearest candidate each side (tie → session); pending neighbours render
  italic as "pending review – <surface>". Adjacency boosts deliberately
  stay on the sessions-only lookup — a pending neighbour is evidence of
  nothing — pinned by checks. (4) His naming decision: the button is
  **Clear** (⌫/⌘D unchanged), and a Clear NO LONGER TEACHES
  (`Target.teachesAttributor` false for `.doNotTrack`): no sticky, no
  learned don't-track lean, no future clock-stop from clearing; past
  clears' learned associations stay untouched; the timeline's "Don't
  track this" keeps its deliberate teach. Manuals updated in fresh-reader
  voice (both `MANUAL.md` and the site's queue + keyboard pages). Checks
  749/0; release app + site build verified.

- [x] **Undo: duplicate reconcile is reversible (the reconcile journal).**
  `applyReconcile` deletes duplicate entries at the backend, so a naive
  undo would re-point sessions at dead ids (later edits would PATCH a
  404 — the reason the audit left it open). New Core
  `DuplicateReconcile.undoPlan` / `ReconcileUndoPlan`: snapshotted BEFORE
  the apply mutates anything, it holds the doomed entries verbatim, the
  survivor's pre-merge comment (nil = the apply never touched it, "" =
  actively clear a comment-less survivor) and each re-pointed slice's old
  entry id. The registered ⌘Z re-creates each deleted entry at the backend
  (fresh backend-assigned ids; activity names mapped back through the
  cached activity list), restores the survivor's comment, and re-points
  each slice at its OWN entry's fresh id — a slice whose re-create failed
  stays on the survivor (live, never a dead id). Checks: plan snapshot
  contents, comment-restore semantics (empty vs hands-off), and a pure
  apply+undo round-trip replaying the controller mechanics.

- [x] **Undo: invoice unlock and retry-stuck are reversible.** The two
  posting-health repair gestures joined the app-wide ⌘Z stack (decision:
  deliberate repair is still a data edit). `SyncEngine.unlockInvoice` now
  returns the lifted rows as they stood and `relockInvoice` is its inverse:
  refs and a divergence parked-while-locked restored, the sticky
  "never re-lock this ref" suppress forgotten (new
  `JournalStore.removeUnlockedInvoiceRef`, implemented in InMemory +
  SQLite), and any row whose entry id moved on (delete+recreate amendment)
  left alone. `retryStuck` moved into SyncEngine, returns the cleared rows,
  and `requarantine` is its inverse — skipping rows the freed retry already
  posted (entry id would be lost → double post) or holds `.inflight` (F12
  intent row). AppController registers both inverses on the undo stack.
  Checks: store conformance for add/remove unlocked refs (both stores),
  unlock→relock round-trip incl. suppress, moved-on-entry guard,
  re-quarantine incl. posted/inflight guards.

- [x] **Undo: one ⌘Z unwinds a whole AI-assist batch.** `ingestAIResponse`
  applied N parsed assignments as N separate undo steps — backing out one
  paste took N presses. The TODO note parked this on "grouping means making
  the call async (UI ripple)"; instead `UndoStack` gained a synchronous
  group flavour (`groupSync`, same fold-into-one-entry + nesting semantics
  as the async one, shared begin/end helpers; a distinct name because
  trailing-closure syntax would let a `group` overload capture existing
  sync-bodied `await group { … }` callers), so the existing sync call site
  groups without any signature change. New UndoStack checks:
  the AI-batch shape (N sync-registered assignments, one entry, one undo
  restores all), empty sync group pushes nothing, sync-in-async nesting
  folds into the outermost.

- [x] **Review drawer: adjacency-based certainty boosts + ranked assign
  buttons.** Martin's spec: the same activity tracked immediately before
  and after a slice should significantly raise the slice's certainty of
  being that activity; one-sided adjacency raises it less; the assign
  buttons sort by decreasing certainty, carry it as a percentage, and hover
  with the reasoning build. New pure `AdjacencyBoost`
  (timeandeyeCore/ReviewDetail.swift): both contiguous same-task sides
  close 60% of the gap between the base certainty and
  `Attributor.inferredCeiling` (0.95 — pins stay the only 1.0), one side
  closes 30%; "immediately" is full-strength up to the 30s switch buffer
  and decays linearly to zero at 15 min (two-sided averages its sides, so
  it hands over continuously to one-sided as a neighbour decays). All four
  constants are documented `static let`s in one place for a one-line
  retune, and every applied boost is DebugLog'd (base→boosted + reasoning)
  so they can later be fitted from correction outcomes.
  `AppController.adjacencyScores` scores a selection with ONE journal range
  query (per-slice neighbour lookup filters in memory; selections past 120
  slices score an even sample, and the hover quotes the aggregated count),
  memoised per segment-id set so keystroke re-renders cost a cache hit.
  Stacks aggregate by the MEAN of per-slice boosted certainties — the
  button answers "how sure are we ALL these slices are this task"; a max
  would let one strong slice oversell. Drawer wiring: the slice detail's
  certainty line folds the boost in with its reasoning; the assign-bar task
  buttons sort by descending boosted certainty (stable — unscored tasks
  keep the ranked pick-list order), show their percentage, and hover with
  base source + adjacency ("learned associations + priors 45% · follows X
  (+18%) → 60%"); ↵-on-filter assigns the same top button the bar shows.
  Display/ordering ONLY — journalled certainty and auto-push semantics are
  untouched (follow-up parked in TODO.md). Source-word vocabulary moved to
  Core (`AttributionExplanation.Source.plainWord`) so the detail line and
  hovers can never drift. New AdjacencyBoost checks: 60/30 gap-closing,
  ceiling clamp incl. pin pass-through, decay endpoints + midpoint,
  two-sided→one-sided continuity, same-task requirement, `.doNotTrack`
  never boosts, negative-gap safety, mean aggregation + honest slice
  counts, hover text, stable button ordering. Manuals (root MANUAL.md +
  site auto-tracking page) gained the likelihood-sorted-buttons paragraph.

- [x] **Review drawer: dated rows, full per-slice detail with tracked
  neighbours, per-slice assign, ⌫ = Do not track.** Martin's 2026-07-10
  critique (UI/data slices). Every stack row and expanded slice carries its
  day (Today/Yesterday/short date; `RelativeDay` in the new
  timeandeyeCore/ReviewDetail.swift) — an Oldest sort was unreadable on
  times alone. Every stack expands (a single-slice entry opens straight
  into full detail), and each slice's own disclosure shows 100% of what's
  held: exact start/end timestamps, duration, app · title · url, email
  correspondents/subject, the attributor's current certainty + its source
  (Evidence Card vocabulary, scored at the slice's own moment), and what
  the journal tracked immediately before and after — task + time, with an
  explicit "…2h gap" when not back-to-back (`SliceNeighbours.around`, a
  read-only range query over existing sessions; no schema change; the
  live-checkpoint sentinel excluded). Each slice in a stack gains an
  **assign** affordance that scopes the assign bar to that one segment —
  the same `assignReview` path, so it teaches from that slice's evidence
  only and lands on the app-wide undo stack. ⌫ with rows selected triggers
  the assign bar's "Do not track" (List `onDeleteCommand`, same ⌘Z). New
  ReviewSliceDetail checks: calendar-day classification incl. the
  just-past-midnight boundary, nearest-neighbour choice, gap + contiguity
  tolerance, overlap exclusion (a slice's own session is never its
  neighbour), and per-slice routing (siblings stay stacked; single-slice
  teach carries only that slice's evidence). Manuals (root MANUAL.md +
  site auto-tracking page) describe the row anatomy; ⌫ joined ⌘D on both
  keyboard pages. The button's NAME stays pending Martin's call (TODO).

- [x] **iOS companion displays as Time&I; inert bundleIdPrefix dropped;
  manual catches up; one bezier evaluator in the checks.** ios/project.yml
  now sets `INFOPLIST_KEY_CFBundleDisplayName: "Time&I"` (the companion
  installed as "andeye"; apps are <X>&I) and drops `bundleIdPrefix` — the
  explicit `PRODUCT_BUNDLE_IDENTIFIER` was already the single source and
  keeps the per-app-id comment; Martin: regenerate with `cd ios &&
  xcodegen`. Manual (root MANUAL.md + site pages): the Evidence Card's
  "sees:" line names the correspondent-capture providers (Gmail, Outlook
  Web, Proton Mail, Yahoo Mail, Fastmail), and the Time window pages say
  Time&I windows appear over full-screen apps and settle onto the current
  desktop; site builds clean. ThemeChecks' inline bezier polynomial +
  duplicated bbox sampler are gone: the rendered SwiftUI path's elements
  funnel into `AndeyeLogo.Cubic` (moves/lines degree-elevated) and both
  suites measure through the AndeyeLogo suite's `curveBBox`. TODO.md gains
  the AndeyeLogo-geometry relocation entry (out of timeandeyeCore into the
  theme/a leaf brand target; consumers listed; waits for a quiet window).

- [x] **Install scripts: never delete an install on evidence you couldn't
  read, verify the zip before touching anything, retire duplicates from
  both locations.** make-app.sh retired `~/Applications/timeandeye.app`
  whenever grep FAILED to find the current bundle id in its plist — a
  missing or unreadable plist (e.g. a half-finished zip install) counted
  as "legacy" and got `rm -rf`'d, and the dotted id was matched as a
  regex; the retire now requires the plist to exist, be readable, and
  verifiably lack the id (`grep -qF`). install-timeandeye.command removed
  the installed app BEFORE checking the zip actually contained
  `timeandeye.app` — a stale pre-rename zip root left the user with NO
  install — and leaked its temp dir on the abort paths; the extracted
  bundle is now verified first and an EXIT trap cleans the scratch dir on
  every exit. And the installer retired only ~/Applications copies while
  make-app.sh sweeps both install locations, so a machine that used
  make-app.sh before switching to zip installs kept a second live
  com.timeandeye.mac at /Applications — the duplicate-registration state
  both scripts' comments blame for the "andeye+" mislabel; the installer
  now retires /Applications/andeye.app and /Applications/timeandeye.app
  too, best-effort without admin rights (it warns and points at Finder
  instead of dying when /Applications isn't deletable). shellcheck: no
  new findings on either script.

- [x] **Email capture review findings closed — flood/garbage/unicode
  verdicts, stale-URL + OWA gates, probe parity, atomic debug log.** Seven
  findings on the recipe-pack/validate-on-use work below. A reply-all
  storm past the 12-counterparty cap was branded suspect — dropping
  enrichment the pre-validation code delivered AND striking recipe health
  toward a pointless re-learn; a new `flooded` verdict now enriches with
  the sender + leading recipients (capped at 12) and leaves the health
  streak untouched (its parties parsed, so it must never strike; its
  untrusted tail is no proof of soundness, so it doesn't reset either).
  EAI/unicode addresses (`杨@example.com`, IDN domains) failed the
  ASCII-only shape test and such reads misclassified as noParties: the
  Swift pattern is now pragmatic-unicode (`\p{L}\p{N}` local part and
  labels, letter-led final label that still admits punycode), hoisted into
  static compiled regexes (they compiled per call on the capture hot
  path), and the capture JS mirrors the shape with negated character
  classes since backslashes/quotes can't travel the AppleScript embedding
  — Swift's `isAddress` stays the strict gate. The JS's `if(em)`
  pre-filter had made the `garbage` verdict unreachable from live paths
  (an attribute redesign — addresses swapped for opaque tokens — reported
  as noParties, misleading diagnosis and the future re-learn loop): the JS
  now reports the count of matched-but-unparseable nodes as a third
  record-separated field, and validation turns empty-parties-with-count
  into `garbage`. `fullCapture` re-gates `isMessageView` on the
  freshly-read URL — the user can navigate message → inbox between
  poll-time gating and the capture running, and a navigated-away read is
  now an error-path no-op, never a health event. The OWA message-view gate
  accepted any ≥16-char id/itemid param anywhere on the outlook hosts, so
  calendar/settings/deeplink tabs classified as open messages and fed
  noParties strikes; it now requires the /mail/ route segment alongside
  the id. The diagnostics probe validated with EMPTY own-address sets
  while live capture threads the user's — a self-only thread printed
  "healthy (1 counterparty)" naming the user's own address; the Settings
  sets now travel into `buildReport`, so probe and live verdicts agree.
  And `DebugLog.write`'s unsynchronised seek-then-write pair — hit from
  the capture queue (`onRecipeUnhealthy`) and the main thread
  simultaneously, interleaving lines in the exact artifact pasted for
  diagnosis — is now a single O_APPEND `write(2)`: atomic per line,
  lock-free, still signal-handler-tolerant for the crash paths. Suite
  706/0; release timeandeyeApp builds.

- [x] **Colour anchor repair made deterministic, gated and universal — it
  now runs at every colour read, not just the pie.** Closes six review
  findings on the same-day repair below (whose over-claim is corrected in
  place there). The problems, in dependency order: `colour(for:)`'s
  first-sight path (timeline, popover MiniPie, Settings) minted an "auto"
  anchor for any project without a record, both shading the newcomer around
  the wrong hue and permanently closing the repair before the pie — the
  only repair site — rendered; the anchor derived from the pie's CURRENT
  first child (seconds-in-range sort), so which colour "won" depended on
  what period you happened to view first; a post-engine user override
  counted as a "pre-engine colour" even for a brand-new project (false
  "migrated" stamp, engine allocation bypassed); the nil-provenance
  sentinel was one old-binary round-trip away from re-arming (decode drops
  unknown keys, re-encode loses them all); tasks auto-shaded around a
  poisoned anchor kept their wrong hues after the anchor healed; and with
  an "auto" first child the repair never fired at all. The fix, all in
  `ColourEngine.repairProjectAnchor` + a controller gate that runs BEFORE
  every `projectRecord`/`taskHex` site: a project is repairable only when
  it verifiably predates the engine (≥ 1 migrated member task record —
  overrides carry no date, so they anchor only a proven pre-engine
  project, and only when they sit on the legacy child itself); the legacy
  child is the earliest-snapshotted migrated member, ties broken
  lexicographically — an honest, store-deterministic approximation, since
  which child the ring actually wore depended on the viewed period and is
  unrecoverable; colours.json gains a `version: 2` stamp and the repair
  era is closed by a one-time `colours.repaired` marker file OUTSIDE the
  JSON (old binaries strip in-JSON fields but never touch the marker;
  residual risks reasoned out in the code comments — a re-armed repair
  re-derives the same anchors, so even the worst case is a colour no-op);
  in a pre-v2 store an "auto" anchor on a pre-engine project is itself
  repairable (it can only be the broken window's pick, days old, vs a
  legacy colour seen for months); a repaired anchor RE-SHADES the
  project's "auto" task records around the restored hue (documented
  judgement: those records are days old and already moved once — leaving
  them was a permanent intra-project clash; migrated records and user
  overrides never move, firstSeen preserved); and once a complete task
  cache has been swept (successful backend refresh, or standalone), the
  leftover nil-provenance anchors — projects that resolve to no cached
  task, so have no restorable legacy colour — are adopted as "auto" with
  their colours intact, the marker lands, and the store is fully stamped.
  What still cannot heal, honestly: anchors whose projects never become
  resolvable before the era closes, and anything a pre-provenance binary
  mints after the marker exists. Gap-sweep addendum, same day: a GREY
  legacy colour (e.g. a #888888 override) has OKLCH chroma ≈ 0, so the hue
  derived from its hex is atan2 quantisation noise (red-ish) — the repair
  would have committed a permanent red task-neighbourhood matching nothing
  the user saw. Below a chroma floor the ring keeps the grey hex but the
  allocation hue falls back to the first chromatic migrated member (a
  colour the project genuinely wore), else to the engine's own
  most-distinct-free-hue allocation. Six new ColourEngine checks (20
  total) pin the bypass survival, deterministic child choice,
  override-hijack rejection, cohort re-shade, version/adoption semantics,
  and the achromatic-hue guard. 703/0; release timeandeyeApp builds.

- [x] **Fullscreen pose: the decision is now a pure, check-covered type.**
  Closes the review findings on fix nine's window/Space logic. The whole
  float-over-fullscreen verdict moved out of SpaceJoiningView into
  `FullscreenPose.decide` (timeandeyeMac — Foundation-only, so the checks
  cover the full matrix without AppKit; 10 new checks). Behaviour fixes
  riding the extraction: the settle stickiness is TIME-based (~5 s of
  continuous non-fullscreen look) instead of 3 samples, so SwiftUI render
  bursts can no longer spend it in under a second — updateNSView is
  identity-upkeep only and the 1 Hz timer owns sampling; grace samples no
  longer pre-count against it; the grace runs on the monotonic clock
  (systemUptime), so an NTP step can't stretch or kill it; the app now
  TELLS the pose logic when its own menu-bar popover is open (the reveal
  that blinds the heuristic) and sampling holds — no demotion however long
  the popover stays up, and no false promotion of settled windows; hidden
  retained windows are silently MAINTAINED in the fullscreen-capable pose
  (AppKit re-asserts flags on them, so a pose parked once wouldn't stick)
  so a reopen orders front already wearing it, with logs gated to visible
  windows or decision changes; users with menu-bar auto-hide (the
  heuristic's permanent blind spot — every desktop looks fullscreen) get
  the float behaviour disabled wholesale via the `_HIHideMenuBar` global,
  windows plain-normal (trade documented; richer positive detector is a
  TODO). Hygiene from the same review: the re-check timer runs in
  `.common` runloop mode (ticks survived menu tracking/drags) with 0.2 s
  tolerance; teardown lives on the window-nil detach path with deinit as
  a main-hopping backstop; and the behaviours log prints the flags READ
  BACK from the window, not the requested value — the fullScreenNone saga
  was only diagnosable because the log showed what AppKit actually kept.

- [x] **Fullscreen fix nine: open-grace + sticky settle, and windows stop
  following you.** Two blind spots from Martin's morning report: opening
  from the menu-bar popover REVEALS the menu bar, so the fullscreen-look
  heuristic read false at exactly the open instant — fresh windows attached
  at normal level and macOS evicted them to another Space (the already-open
  timeline floated fine on its attach-time flags). Windows now OPEN in the
  fullscreen-capable pose (floating + canJoinAllSpaces) and settle after a
  4s grace, with a sticky 3-sample demotion so a transient menu-bar reveal
  can't flicker them off a fullscreen Space. The pose is now conditional
  both ways: once settled on an ordinary desktop the window drops
  canJoinAllSpaces and floats no more — no more following the user to
  every Space. Hidden retained windows are left alone (AppKit re-asserts
  flags on them; touching them back churned behaviours and logged once a
  second for a closed timeline). The activation gate accepts floating
  windows (over fullscreen nothing is ever at normal level, so activation
  never fired there and opens finished stranded on another Space).

- [x] **Colour migration repair: seen projects get their pre-engine colours
  back.** Martin's regression report: after the colour engine landed
  (7b4aed6), projects turned dull and their bright tasks looked unrelated.
  Diagnosis: the v1 migration snapshotted TASK colours faithfully (his task
  colours never actually changed), but project ring/legend colours were
  re-derived from fresh engine anchors — pre-engine the project wedge wore
  its first child task's bright legacy colour, so every already-seen
  project changed colour, and the preserved random-hue task colours stopped
  matching their project. (Ring-3 window wedges were always the task colour
  at alternating opacity — unchanged, just newly conspicuous.) Fix:
  `ProjectRecord` gains provenance ("auto" for engine picks, "migrated" for
  snapshots; the 2026-07-09 build's records decode as nil), and
  `ColourEngine.snapshotLegacyAnchor` anchors a project to its first
  child's pre-engine colour (override or migrated record), with real OKLCH
  coordinates derived from the hex so future tasks shade around the
  familiar hue. It fires from `projectColour(containing:)` at pie render —
  and, corrected same-day (see the deterministic-repair entry above): ONLY
  there, and only when the pie's current first child happened to carry an
  override or migrated record — a new task first-sighted from the
  timeline/popover/Settings paths could mint an "auto" anchor first and
  close the repair before the pie ever rendered, so healing was NOT
  guaranteed on next launch as this entry originally claimed. It may
  overwrite exactly one kind of record: a provenance-less anchor from the
  2026-07-09 build, the record that itself broke the "nothing already seen
  changes" promise; repaired/auto records are closed forever, so the repair
  is idempotent and terminating. Three new checks pin the legacy
  first-child snapshot, the poisoned-store recovery (driven from a decoded
  provenance-less JSON fixture), and the project-vs-task derivation split
  (anchor swatch from the display ladder, tasks from the ±25°
  neighbourhood). Pie colour EDITING (also asked for in the report) is a
  separate TODO item, not this fix.

- [x] **Email recipe pack: Outlook Web, Proton Mail, Yahoo Mail and Fastmail
  join Gmail.** `EmailSystem` now ships open-message sender/recipient
  selectors for all five webmail systems, each with its evidence source,
  retrieval date and an honest confidence note in the code (Proton is
  authoritative — read straight from ProtonMail/WebClients source; OWA and
  Yahoo are cross-corroborated across independent browser-extension
  extractors; Fastmail is a weak best-candidate from Fastmail's own
  jmap-demo-webmail class conventions). None is verified against a live DOM
  yet — validate-on-use (2026-07-10, above) is the designed guard: a wrong
  selector yields a suspect read that never enriches and self-reports
  unhealthy. Around the selectors, three model fixes: host detection is now
  ANCHORED (a bare `hasSuffix` accepted lookalikes — "notmail.google.com"
  ends with "mail.google.com" — and every match injects recipe JS into the
  page); every provider got a message-view gate mirroring Gmail's stale-DOM
  guard (OWA `/id/<item>` + pop-out `itemid` query, Proton `/u/<n>/<label>/
  <element>` with custom-folder labels excluded, Yahoo `/messages/<id>`,
  Fastmail `/mail/<mailbox>/<thread>` — all fail closed); and the capture JS
  reads addresses through a provider-neutral ladder (`email`/
  `data-hovercard-id`/`data-email`/`title`, then address-shaped text) so a
  recipe only has to find the sender element, not name the attribute. New
  `EmailSystemRecipes` checks pin the detection matrix (incl. lookalike
  hosts), the per-provider gates end-to-end through `captureTarget`, and the
  embedding invariant (selectors travel single-quoted-JS-inside-AppleScript,
  so no quotes or backslashes — Proton's `:`-bearing testids use substring
  matchers). Native clients (Apple Mail/Outlook desktop) stay open in TODO —
  different capture channel.

- [x] **Email recipes now validate on use, with per-system health telemetry
  and safe degrade.** The NAIL programme's cheap half: a webmail redesign or
  a localized From label never errors, it just makes a recipe silently return
  nothing or junk — so every error-free capture is now judged by the shape of
  its output (`EmailRecipeValidation`, pure Core: healthy = plausible
  counterparties; self-only = recipe fine, note-to-self, never a failure;
  suspect = no parties on a confirmed message view, nothing address-shaped,
  or a list-scrape flood). Suspect reads never enrich the signal — no
  polluted correspondents reach learning or EmailRules; subject-only
  enrichment still flows. `EmailRecipeHealth` keeps a per-system
  consecutive-failure streak on the engine: three in a row marks the system
  unhealthy, writes the debug log, and fires `onRecipeUnhealthy` — the
  documented seam where the future re-learn loop (probe → label →
  store-recipe) attaches; any healthy or self-only read resets the streak.
  Transport failures (missing Automation grant, JS off, deadline) never touch
  health by design. The email probe report and probeEmailSender diagnostics
  print the verdict and health lines. Eight new checks cover the redesign
  shapes, the self-only/failure distinction, and the streak threshold/reset.
  Suite 677/0.

- [x] **timeandeyeTheme: the shared andeye look as its own SwiftUI-only
  target.** The a sibling project's coordination request, needed by a sibling andeye app v0.3:
  AndeyeTheme.Colours (the highlight moved from timeandeyeUI — AndeyeColors
  stays as a compatibility spelling — plus the brand amber #F0A13A),
  AndeyeTheme.Fonts (a semantic type scale distilled from the app's real
  usage), and AndeyeMark/AndeyeMarkView — the first in-app SwiftUI renderer
  of the AndeyeLogo geometry (arc-length reveal + wink, both animatable;
  stroke weight scales per the SVG's 17/365). No AppKit anywhere in the
  target, so sibling apps consume theme without the macOS app layers.
  timeandeyeUI now depends on it; product `timeandeyeTheme` exported (Mon
  pins branch FableMax until main). Four checks pin the render contract —
  faithful scale/centre/flip of the Core geometry, wink moves lids not
  footprint, SVG stroke ratio, alias identity. Suite 669/0.

- [x] **Docs truth pass (findings 7–8, 11–12).** The 2026-07-09 rebrand
  entry corrected: the backend key lives in an owner-only file, not the
  Keychain (no Keychain code exists in Sources; a 2026-06-24 entry had
  already corrected this claim once), and the quit-wait sentence now
  covers both hardened install paths. the verify command runs
  timeandeyeChecks (the andeyeTTChecks product no longer exists).
  Predecessor session audit's uncommitted-inventory line fixed (the
  checks.yml rename was committed as 59d87b2).

- [x] **iOS companion bundle id is com.timeandeye.ios (finding 10).** The
  per-app-id decision applied to Time&I's iOS app while no App ID,
  provisioning or App Store Connect registration exists to migrate — the
  same free-rename window the Mac id used, which closes permanently at
  first registration. Regenerate the project on the Mac: `cd ios &&
  xcodegen`.

- [x] **Id-transition hardening (post-rebrand /code-review, findings 1–6,
  13–14).** Both upgrade paths — scripts/make-app.sh and
  scripts/install-timeandeye.command — now quit BOTH identities guarded by
  `is running` (a bare `quit app id` LAUNCHES a registered-but-dormant
  bundle just to deliver the event; one of the two ids is always not
  running, and stale old-id staging bundles exist), then wait and ABORT
  rather than swap the bundle under a still-running process (a denied
  Automation prompt fails silently — the new Terminal→com.timeandeye.mac
  pair has never been granted). make-app.sh single-sources
  BUNDLE_ID/LEGACY_BUNDLE_ID (plist stamped via sed like BUILD_STAMP) and
  retires old-identity bundles in ~/Applications too (the zip installer's
  location). Stale "the id is shared"/"same bundle id" comments corrected.
  Shim expiry recorded in TODO.md.

- [x] **Review drawer joins the 1Hz fullscreen-level re-check.**
  (Backfilled entry — documents commit 24e3959, which landed without
  one.) The float-over-fullscreen level decision rode SwiftUI re-renders,
  ~1Hz for clock-driven windows but rare for the review drawer, so the
  drawer never updated its level after attach and stayed evicted from
  fullscreen Spaces while timeline and settings floated. SpaceJoiningView
  now owns a 1s timer plus a screen-change observer, giving every window
  the same re-check cadence regardless of render frequency. Suite 677/0
  at the time; release build verified over the bridge.

- [x] **Site legal canonicals pinned to andeye.com.** (Backfilled entry —
  documents commit 47de277, which landed without one.) One privacy policy
  and one terms doc for ALL andeye apps: the Xero-registered
  andeye.com/privacy + /terms stay the reference wherever the product
  site is served, so the legal pages' canonicals are absolute now
  (Astro.site is time.andeye.com and was silently re-canonicalising them)
  and both footers link the andeye.com URLs.

## 2026-07-09

- [x] **Bundle identifier is com.timeandeye.mac.** Martin's per-app-id
  decision: every andeye app gets its own identifier (a sibling andeye app etc. cannot
  share one), so Time&I takes com.timeandeye.mac now — before the entitled
  build, while no iCloud container or provisioning exists to migrate. The
  planned container becomes iCloud.com.timeandeye.mac. One-time cost on
  the next launch: macOS re-asks for Accessibility/Automation/Calendar.
  The backend key is unaffected — it lives in an owner-only file under
  Application Support, not the Keychain. The upgrade quit-waits (both
  install paths, hardened 2026-07-10) handle both old and new identities
  during the transition.

- [x] **Full rebrand: modules andeyeTT* → timeandeye*, human name Time&I.**
  Martin's final naming directive (`<X>&I` / `<x>andeye` / `<x>.andeye.com`
  only; capital I supersedes the earlier "Time&i"; the long form "Time
  andeye" is retired). SwiftPM package `andeyeTT` → `timeandeye`; every
  target/product/directory renamed via `git mv` (andeyeTTCore →
  timeandeyeCore, ~Store, ~Mac, ~UI, ~Phone, ~Checks, ~Integration;
  andeyeApp → timeandeyeApp) with all imports, CI (`swift run
  timeandeyeChecks`), ios/project.yml package+product refs (regenerate
  `andeye.xcodeproj` with `cd ios && xcodegen`), and docs (CLAUDE.md,
  README, CONTRIBUTING, MANUAL.md, site manual pages, entitled-build)
  following. Human strings: CFBundleName AND CFBundleDisplayName are both
  now `Time&I`; window titles, Settings/About fallback, usage-description
  strings, manuals and site copy all read Time&I. Deliberately UNCHANGED:
  CFBundleIdentifier `com.andeye.mac` and the signing identity/keychain
  (TCC grants), CFBundleExecutable `andeye` (quit-wait during upgrades),
  Swift type names (`Andeye*` — the brand lives on, only TT dies), and
  
  Product-site domain refs aligned to time.andeye.com (astro `site:`,
  canonical, manual link); andeye.com/terms + /privacy left —
  Xero-registered, "must not change". Mac to run: `rm -rf .build && swift
  run timeandeyeChecks`.

- [x] **Site recipes v1: pluggable page understanding beyond Gmail.**
  Closes NAIL item (e) per the 2026-07-09 site-recipes spec (§11 v1 cut;
  §0 questions resolved as the spec's own recommendations). Tier 0 ONLY —
  every field parses from the URL + window title the sensors already
  capture; no DOM probe, no new permissions, no Sensors change. New Core
  model `SiteRecipe` (Codable data: anchored-suffix hosts, a declarative
  `URLShape` view gate carrying the Gmail staleness lesson, an ordered
  field list that IS the grain ladder, per-recipe default grain) with
  three built-ins: GitHub (owner/repo/section/issue-title), Google
  Docs/Drive (type/document-id-keyed-but-title-displayed/title), Xero
  (organisation/section/page-title — extractors ASSERTED FROM MEMORY,
  clearly flagged in code + fixtures, to be verified live via the new
  Settings ▸ Diagnostics "What recipes see here" row before trusting).
  `SiteRule`/`SiteMatcher` land as the third rule domain mirroring
  EmailRule/CalendarRule (deliberately parallel, refactor deferred):
  most-specific-wins over `["site"] + recipe fields`, pinned-beats-learned,
  newest-unpinned ties, content fields substring-matched; the reserved
  recipe-less `site` level makes "this site → task" learnable on EVERY
  non-mail web page (ambiguous-page policy note, host half). Attributor:
  `siteRuleMatch` on the SAME 0.95 rung as email rules (host-disjoint by
  construction — mail hosts never produce a SiteContext), fire provenance
  + `onFirstSiteFire`, and the full forget/explainWithout/
  forgettableWithout family with siteRules added to every snapshot.
  ContextIdentity: recipe pages now chain host + ◆ fields (ghosts for
  missing values, content quoted last), REPLACING the raw path segments
  (the old splice-at-1 would have duplicated them; no live callers);
  recipe-less URLs keep the PinScope chain byte-for-byte. Teach surfaces:
  Evidence Card ladder + popover/review grain footers commit SiteRules
  (Remember learned / Always pinned; host-row Always stays the PinScope
  root pin), footers now offer on any web page and a disagreeing review
  batch degrades to the shared site grain — review rows gain recipe
  grains retroactively (derived from stored tabURL/windowTitle, no schema
  change). Learner: `.recipeField` features ("github.repo=example-repo"),
  identity fields only, additive decode (unknown feature kinds now land
  as `.unknown` instead of bricking learning.json); the Xero-T&Cs
  compliance check extended to recipe'd hosts (screen-observed only).
  Ledger: "Sites" segment (provenance, row disclosure, per-group bulk
  forget, Copy rules) + the Recipes toggle strip (default on; off =
  extracts nothing, rules dormant-not-deleted; `siteRecipesDisabled`
  setting mirrored into the attributor). Every mutation registers undo
  via the shared attributor snapshot (post-undo-audit pattern);
  siterules.json persists beside emailrules.json. Gmail pipeline
  untouched (migration deliberately deferred). Six new check suites
  (extraction fixtures incl. staleness/view-gate cases, chain shape,
  matcher semantics, attributor precedence + un-learn round-trips,
  feature gating + compliance, ledger grouping/export). UNVERIFIED —
  suite not run (no Mac in this container).

- [x] **Undo audit: every data action now ⌘Z-able, exactly.** Martin:
  "check every action can be infinitely undone" (trigger: a comment edit
  grew a sub-minute slice, the growth fused it into a neighbour, and ⌘Z
  then operated on the fused row). The fusion half: `coalesceAdjacent` now
  registers a compensating undo built from a new pure
  `TimelineMath.coalescePlan` (absorbed originals + each survivor's
  prior/merged pair), and the timeline save calls it INSIDE the edit's
  undo group — one ⌘Z restores the exact pre-edit rows, never a fused row
  (`applyTimelineEdit`'s inverse now also trusts the current row's remote
  linkage so an un-fused row never points at a deleted backend entry).
  Registration gaps closed: local-task rename, pin/unpin/pin-edit,
  Evidence-Card teach/boost and grain commits (single + correspondent
  fan-out), popover comments (in-flight note only — a copy already posted
  to the task's feed stays posted), idle-gap claim (one step, and undo
  re-surfaces the offer), don't-track (slice back AND the suppression
  unlearned), billing mapping, consolidation, hard-cap prune (undoable
  until quit — the manuals' "no undo" wording corrected). Partial
  restores made exact: assign/change/reassign/split/allocate/move undos
  now restore the attributor wholesale (learning, primes, stickies via new
  `Attributor.replaceSessionStickies`, displacement history) plus taught
  calendar rules; removed local tasks return to their original list
  position; live-start extensions pull the clock back off restored rows
  via new `SessionTracker.trimSessionStart` (backdate's exact inverse).
  `UndoStack` confirmed uncapped — "infinite" holds within a session;
  relaunch starts fresh (retro-acceptance's persistent "Recently cleared —
  undo" digest is the deliberate exception and survives relaunch). Checks:
  coalesce-plan round-trip, the incident shape end-to-end (edit + fusion
  in one group undoes to exact rows), backdate→trim round-trip, 10k-deep
  uncapped stack. Known non-undoables (by design, reported): duplicate
  reconcile (remote entries already deleted), unlock-invoice/retry-stuck,
  live pick/stop (compensators: ← revert, timeline edits).

- [x] **Review queue: sort control + range-select sweep.** Martin,
  mid-backlog: "sort by fields at the top: time, duration, and the ability
  … to select (at least with shift click start and end of selection) so
  they can get rid of everything underneath whatever duration or before
  whatever date". A header menu picker orders the stacks newest/oldest (by
  each stack's LAST activity — so "everything above the cutoff" really is
  entirely before the date) or longest/shortest (by total time), persisted
  in settings (`reviewSortOrder`, default newest — the historical order).
  Comparators are pure Core (`ReviewSort.swift`) with deterministic
  tie-breaks, checked in `reviewSortAndRangeChecks`. Range selection
  itself already existed — the drawer's List is NSTableView-backed, so
  shift-click/⌘-click/⇧↑⇧↓ extended selection came native, and the
  multi-stack assign path (`assignReview`) already batches the whole
  selection into ONE undo step and teaches per distinct surface — the sort
  is what makes a range MEAN "below this duration / before this date".
  `ReviewRangeSelect.range` encodes the range contract (inclusive
  endpoints, current display order, vanished-anchor degrades to the
  clicked row) for the checks and for non-AppKit surfaces later. Selection
  survives a sort change by surface id (it means "these surfaces", not
  "these positions"). MANUAL.md + site manual (attribution + keyboard
  pages) gained the sweep recipe.

- [x] **Fullscreen fix five — the poison bit, found by log.** Martin's
  debug-log paste showed SwiftUI Window scenes ship with `fullScreenNone`
  set, which contradicts `fullScreenAuxiliary`; macOS resolved the
  conflict against every previous flag combination (they only INSERTED
  bits) and placed the window on the next desktop at the moment it became
  visible. The bit is now removed and the windows use `moveToActiveSpace`
  + `fullScreenAuxiliary`: they appear on the Space — fullscreen included
  — where they were opened and stay there, exactly the stay-put behaviour
  Martin asked for (no follow-everywhere).

- [x] **Quiet while presenting.** While the mic is live (the call
  detector's own signal) or any display is mirrored, floating banners that
  would name a task or contact are suppressed — a toast naming a client on
  a shared screen is a privacy leak the context-rules focus group flagged.
  Content-free banners ("Stopped", "Welcome back") still show, the
  suppressed information stays reachable in the popover, and the idle-gap
  claim survives suppression. Settings toggle, on by default; detection is
  conservative (a false positive costs one banner).

- [x] **The app is now Time&i (bundle timeandeye.app).** Martin's final
  naming: repo and app name `timeandeye`, human short form **Time&i**
  (lowercase i), long form **Time andeye**; "andeye" continues as the
  umbrella brand. In-repo: `make-app.sh` builds/installs
  `timeandeye.app` (CFBundleName `Time&i`, CFBundleDisplayName
  `Time andeye`), retires any `/Applications/andeye.app` on install and
  quits the running copy by bundle id so old and new never coexist;
  `install-andeye.command` → `install-timeandeye.command`
  (`timeandeye-build.zip` → `~/Applications/timeandeye.app`, same
  retirement). Deliberately unchanged: CFBundleIdentifier
  `com.andeye.mac` and the signing identity (TCC grants key off them),
  CFBundleExecutable `andeye` (the upgrade quit-wait pgreps it in both
  old and new builds; nothing user-visible shows it), and the SwiftPM
  module names (`andeyeTT*`, `andeyeApp` — andeyePro depends on them).
  Window titles ("Time&i", "Time&i Review", …), Settings/popover copy,
  the About line (now read from CFBundleName), README, MANUAL, site
  manual and repo links (github.com/andeyePro/timeandeye) all follow;
  "andeye" stays in prose where it means the brand, a domain, or an
  on-disk path (Application Support/andeye, the debug log).

- [x] **Idle stops un-stick themselves.** Coming back within half an hour
  of an idle auto-stop resumes tracking on any returned input — a clearly
  recognised surface wins, a plausible one is next, and otherwise the task
  that was tracking resumes at the current signal's honest certainty (so a
  wrong guess queues for review rather than silently billing). Past the
  half-hour bound only the old confident-surface resume applies, and a
  manual stop never restarts on its own. Two tracker checks.

- [x] **Calendar defaults confirmed + time-based meeting alerts (Martin's
  design).** The menu-bar mark now alerts on meeting TIME, replacing v1's
  off-calendar mismatch flash (which never shipped on): a QUIET slow amber
  pulse through the lead-up to each event (lead time a Settings picker —
  1/2/5/10/15 min, default 5) and one VIOLENT unmissable flash (150 ms
  full-strength alternation for ~3 s) the moment it starts, both ON by
  default, both riding the existing `AndeyeLogoImage` flash pose. Pure
  decisions live in Core (`CalendarAlerts.phase`/`nextBoundary`, seeded
  `CalendarEvent`s, no EventKit): pulse window is exactly
  [start − lead, start); the start flash fires once per occurrence
  (`occurrenceKey` = id + start, so recurring instances alert
  independently) within a 60 s grace — an event already underway at launch
  never flashes retroactively; tentative invites pulse but never flash;
  all-day events never alert; back-to-back events each get their own
  lead-up and flash. The popover's "Calendar: <event> – Switch" banner
  stays (mismatch settle logic kept, banner-only now); the whole Settings
  Calendar subsection hides until the signal is on. Martin's other two
  defaults verified already held in v1: birthday/subscription calendars
  excluded by type + name opt-outs; the calendar term stays structurally
  capped below every pin/sticky/URL/email match — now pinned by checks (a
  1.0 pin and a 0.95 primed surface both beat a CONFIRMED calendar match;
  ranked winner ≤ 0.9). New CalendarPrecedence + CalendarAlerts suites;
  `calendarFlashEnabled` removed (lenient decode ignores the stale key).
  Manuals updated both surfaces.

- [x] **Task-colour engine v1 — stable, distinct, colour-blind-aware.** New
  platform-independent `ColourEngine` (andeyeTTCore) replaces the per-task
  djb2-hash hue: each project claims the most distinct-from-neighbours free
  hue on an OKLCH wheel (argmax of minimum pairwise distance, where distance
  is the WORST CASE across normal vision and protan/deutan/tritan simulation,
  Machado 2009), and its tasks take shades from a ±25° hue neighbourhood
  crossed with a lightness/chroma ramp, scored against every colour assigned
  so far — the colour-lab's recommended "strategy C"
  (sites/previews/colour-lab.html; spec
  docs/superpowers/specs/2026-07-06-colour-strategy.md). COLOUR STABILITY is
  the governing rule: an assignment commits to a new colours.json (JSONFileStore,
  beside pins.json) at first render and is data from then on — new items never
  move old colours; hue exhaustion opens a second lightness band instead of
  squeezing band 1. Auto colours are constrained so the UI's black-or-white
  label always reaches 4.5:1. One-time migration snapshots the old hash colour
  for every task with journal time, so an upgrade changes nothing the user has
  seen; user overrides stay in settings.taskColours, checked first, exactly as
  before. The pie's project ring/legend now render the project's OWN anchor
  colour instead of borrowing the first child task's (which changed with sort
  order). Project records share BillableRules' stable keys and ride the same
  title→id key migration. New ColourEngine checks suite: determinism,
  add-N+1-changes-nothing, override-beats-engine (recordless), the lab's
  engineered hash-collision pair, whole-fixture worst-case-CVD legibility,
  label contrast, band-2 engagement, round-trip, snapshot permanence, unfiled
  fallback. iOS PhonePalette still hash-derives (store sync is future work).

- [x] **Windows show over fullscreen apps — proven flag combo.** The Time,
  Review and Settings windows now use `canJoinAllSpaces` +
  `fullScreenAuxiliary` — the exact combination the app's own notification
  panel already uses successfully over fullscreen apps —  instead of
  `moveToActiveSpace`, whose "active space" resolves to the nearest
  DESKTOP, landing the window on the next non-fullscreen Space. The
  windows now sit on every Space while open (utility semantics: close
  them and they're gone), which also means opening one never yanks you to
  another Space. Space decisions are logged to the debug log so any
  remaining failure reports with data.

- [x] **Opening a window over a fullscreen app no longer switches Space —
  activation-order root cause.** The Space switch was never the window's
  doing: `openWindow` is asynchronous, so the immediate `NSApp.activate`
  activated a momentarily window-less app and macOS switched to a Space
  that had its windows. Every open site now defers activation
  (`AndeyeWindows.activateOnceVisible`) until a normal-level window is
  actually visible on the current Space — at which point there is nothing
  to switch away to.

- [x] **Review-queue rows carry their email evidence.** A low-certainty
  email slice now queues WITH the correspondents and subject its signal
  carried, so the drawer's post-assign "remember for…" footer offers the
  same correspondent/domain/subject grain ladder as the Evidence Card
  (including the multi-correspondent checkbox fan-out) instead of falling
  back to the whole mail system — and app-mail rows (no tab URL) get an
  email-grain offer for the first time. Same-surface extensions merge
  evidence (correspondent union, first non-empty subject — the async
  capture races focus changes, so the opening slice may hold less than a
  return visit), and `teachingSignals` unions it per surface the same way.
  Evidence persists inside the review row's existing JSON blob column — no
  schema migration; rows journalled before the fields existed decode as
  evidence-free and keep the old system-level offer, as does a multi-row
  batch whose evidence disagrees (it degrades to the shared mail-system
  grain rather than losing the footer). Stacking and the admission floor
  pass segments through whole, checked. Manuals updated (Review queue
  footer paragraph).

- [x] **Windows join a fullscreen Space before first show.** Opening
  Timeline/Settings/Review over a fullscreen app no longer switches Space:
  the window flags now apply synchronously when the content view lands in
  its window (`viewDidMoveToWindow`), before macOS decides the Space
  transition at order-front — the earlier deferred apply lost that race.

- [x] **Timeline comments visible live, through merges, at a glance.** A
  comment now shows in the timeline the moment it's committed — no stop, no
  gap: the displayed live block's comment is composed from the stored
  comments of the journalled rows it folds PLUS the in-flight note (new pure
  `TimelineMath.foldLive` + shared `joinComments`, unit-checked; previously
  the fold silently dropped folded rows' comments and the live slice carried
  only the pending note, so a comment vanished when its row flushed under
  the live block and only reappeared after stop + a gap). Merged slices
  already kept their joined comment in the journal; the display now shows
  it: every slice's hover tooltip carries its comment, and commented slices
  wear a tiny bubble mark in the slice's label colour. The live slice's
  editor shows the folded stored comments read-only beside the note field,
  which still edits ONLY the in-flight note — open→save-unchanged stays a
  lossless no-op, nothing duplicates between the stored and pending parts.
  `commitComment` bumps `journalRevision` so an open timeline recomposes
  immediately instead of on the 30 s reload. Manuals updated (Time window →
  Comments).

- [x] **Review queue sub-minute floor + "Unknown" button rename.** The
  drawer stops asking about moments not worth a decision: a visit only
  enters the Review queue once its slice is at least `reviewFloorSeconds`
  long (new setting, default 60 s, stepper beside the review-threshold
  slider; 0 shows everything). Per-segment by Martin's call: a visit too
  brief to survive the switch grace never becomes a tracked switch, so
  its identity is never worth a decision however often it repeats —
  brief glances never pool into a queue row (contiguous same-surface time
  already reaches the queue as one extended segment, so genuine long
  visits qualify whole). Applied where the visible queue materialises
  (`reloadReview`) plus the retro pass's unknownAssigned re-add, never at
  flush time, so sub-minute slices stay tracked/journalled untouched (the
  timeline keeps them) and existing persisted sub-minute rows vanish on
  reload with no migration. Assign bar's "Not sure – Unknown" button is
  now just "Unknown" (Martin: synonyms), manuals aligned. Checks:
  ReviewFloor suite + pinned default.

- [x] **Calendar signal v1 — andeye knows what you're supposed to be doing.**
  Read-only EventKit bridge (event-driven, no polling; permission asked only
  when the feature is first enabled in Settings), a calendar→task rules
  ladder shaped exactly like the email one and taught by the same
  corrections, and a bounded ranker term that nudges both live attribution
  and the pick-list order toward the current meeting's task (structurally
  capped below every pin/sticky/URL/email match). The live-matched task
  wears a clock badge; a mismatch >60 s shows a one-line "Calendar: <event>
  – Switch" banner in the popover and can pulse the menu-bar logo gently
  (off by default pending Martin's defaults confirmation); review stacks
  overlapping a past event get a one-click assign hint. Calendar text never
  leaves the device. Two agents + integration (the live prior's attributor
  wiring and pick-list cache invalidation landed at integration). Suite
  553/0, warning-free build, site builds.

- [x] **Approvals drawer v1 — the review pile stops building.** Per Martin's
  same-morning answers to the spec's questions. Retro auto-acceptance:
  a debounced pass after every learning/pin/rule write re-scores the pending
  queue through the attributor's own explain() and clears whatever now
  scores at/above the push bar, lifting + re-pointing the cleared rows'
  UNPUSHED overlapping sessions so they post through normal sync (the
  live-checkpoint sentinel and already-pushed rows are explicitly excluded
  — a bulk pass must never amend posted time). Each pass journals ONE
  RetroDigest (new store table, 30-day retention, both stores) shown in the
  drawer's "Recently cleared" section with a whole-pass Undo. The drawer
  itself is stack-by-default: identical surfaces collapse to one decision
  row with total/count/span, expandable to slices; accepting teaches from
  every surface. The popover badge counts DECISIONS (stacks). The review
  threshold joined the push threshold as a visible Settings slider.
  Suite 525/0 + full release build on the bridge.

- [x] **Rules Ledger: row-click disclosure, bulk forget, "Copy rules" export
  (context-rules spec §6 "later polish").** Clicking a ledger row now
  expands a compact rule-detail disclosure underneath it — provenance
  sentence ("learned 12 Jun 2026 from your correction"), fire count/last
  fired, grain and target task, plus the existing delete affordance;
  `EvidenceCardView` itself wasn't embedded because it's signal-anchored
  and a ledger rule has no live signal to explain. A group's header grows a
  "Forget all" button (shown once a task has more than one rule) alongside
  per-row delete, both going through a new `AppController.deleteRules(_:)`
  that removes every passed rule in ONE undo step (`deleteRule` is now a
  one-row call into it — same confirm-then-undo banner either way). New
  `RulesLedger.exportText` (Core, pure/deterministic) renders every rule as
  plain text grouped by task — grain, value, pinned/learned, fire count,
  createdAt/lastFired — behind a "Copy rules" button next to the search
  field, mirroring the timesheet export's copy-button/"Copied" pattern.
  New checks: `RulesLedgerExport` (empty state, single rule, pinned
  wording, lastFired presence/absence, `.distantPast` createdAt doesn't
  format, multi-task grouping/ordering). UNVERIFIED — no Mac available in
  this container to build/run the suite.

- [x] **iCloud quota stewardship — Settings ▸ Maintenance grows a footprint
  readout and two prune tools.** `JournalStore.journalFootprint()` (new
  protocol requirement, default extension does a real JSON-byte count, the
  SQLite replica overrides with a SQL `SUM(LENGTH(json))`) splits the synced
  session bytes from the local-only window-span bytes honestly — no
  estimate/multiplier. (b) age-consolidation (`JournalPrune.plan`, already
  built and check-covered from an earlier batch) is now reachable: Settings
  gets a years field (`journalConsolidateAfterYears`, default 2), a Preview
  step, and `AppController.applyConsolidation` to run it against the real
  journal. Its comment fold is now also capped (10 distinct comments, then
  "+N more") so a years-long daily-switch history can't produce one
  unreadable row. (c) new `JournalPrune.hardCapPlan` — oldest raw slices
  first, stops the moment an MB ceiling is met, and can never touch a
  consolidation rollup (`SessionMerge.isDerivedID`, reusing the version-8
  "custom" UUID nibble `fragmentID` already stamps rollups with — no new
  stored flag needed). UI is labelled strongly discouraged with two chained
  `confirmationDialog`s (double confirm) before `applyHardCapPrune` runs.
  (d) turned out to be already shipped: `SQLiteJournalStore.purgeTombstones`
  (90-day retention) already runs on every store init — nothing to build.
  New checks: totals-preserved, idempotent re-run, comment cap, and three
  hard-cap checks (no-op under cap, oldest-first + stops at the ceiling,
  never touches a rollup). Suite 500/0 + full release build verified on the
  bridge Mac; the Settings pass (dialogs, field bindings) still wants an
  on-device eyeball.

- [x] **Timeline span-select → Allocate.** Shift-drag (or shift-click, then
  shift-click again to extend) selects a time RANGE on the bar — not bound to
  any slice's edges, so it can cut straight through the middle of one — shown
  as a translucent band with its start/end. A small bar offers Allocate…
  (the same filter+button task picker as the reassign bar/editor) or straight
  to Unknown. A plain drag/click still draws/opens as before; bare ⇧ is the
  new modifier, so the old ⇧-click ID-range-select on a slice moved to ⇧⌘.
  New `SpanAllocation.plan` (Core, pure, checked) classifies every session
  overlapping the range as a whole repoint (fully inside) or a split
  (straddling an edge), reusing the already-checked `TimelineMath.split`;
  the controller's `allocateSpan` applies each action through
  `reassignTimelineSessions`/`replaceSession`, so pushed sessions, undo (one
  step for the whole gesture) and OP re-push all behave exactly as they
  already do for a manual reassign/split. Fixed a latent gap while at it:
  `teachAssociation` now guards on `Target.teachesAttributor` before
  teaching — previously true only by accident (Unknown was never actually
  reachable from `reassignTimelineSessions`/`replaceSession`'s callers), now
  it's an explicit rule so Allocate → Unknown can't silently teach the
  attributor. New checks: `SpanAllocation` (full-inside repoint,
  already-on-target no-op, both-edge split, left-edge split, right-edge
  split, out-of-range sessions absent, a pushed session planned exactly like
  any other, Unknown target no different in the plan, mixed-task sessions
  each planned independently). UNVERIFIED — no Mac available in this
  container to build/run the suite.

## 2026-07-08

- [x] **D6 finance task mapping + criterion-10 reopen — billable OP time can
  route to Xero without stalling on unmapped projects.** New Core
  `FinanceMappingStore` (sourceProjectKey → backend project + default task,
  injected task→project resolver, change signal); XeroBackend resolves
  create/update targets mapping-first (no store = native-only, pinned).
  Unmapped-but-recognised projects skip permanently with a stable reason
  string that doubles as the reopen key: `SyncEngine.reopenMappingSkips`,
  fired from the store's change handler, clears exactly those rows so the
  session posts on the next pass — other skips stay closed. Settings editor
  for mappings ships with the Pro Xero surface (TODO). Mac-verified 472/0;
  Pro 38/0.

- [x] **Invoice-lock layer (Martin's proposal, spec D4b) — billed time can't
  be silently rewritten.** New `TaskBackend.invoiceLocks(for:)` seam
  (default: nothing locks); the sync engine polls it half-hourly (shared
  `InvoicePollClock` throttle across per-pass engines, batch-capped) and
  stamps the invoice ref onto the posting-ledger row. Locked rows are exempt
  from the amendment loop AND the resurrection sweep: a journal edit over
  billed time surfaces on the row naming the invoice instead of amending,
  retracting, or re-posting it. Per-invoice Unlock in Posting health lifts
  the guard and re-arms amendment; the same ref never auto re-locks
  (`unlocked_invoices`), a new invoice does. Xero implements the seam off
  the Projects API entry status (one listTime per project per poll; the API
  exposes no invoice number — verified — so the ref is "Xero" until an
  Accounting API lookup exists). Ledger gains `locked_invoice_ref`
  (additive migration). Mac-verified: 470 passed 0 failed; Pro 38/0.

- [x] **Menu-bar jiggle fixed for real (Martin: "the icon moves… only when
  the time text varies in width").** The hidden sizing-template ZStack was
  not holding the MenuBarExtra label's width, so the AppKit-measured widest
  candidate is now reserved as an explicit `minWidth` on the label — can't
  clip (content still wins if measurement runs low), only stops shrinking.
  Also eye engine v5: the winking bottom lid hinges from the eye's true left
  corner (the computed crossing of the two & strokes, 121.11/138.06), not
  the tail; lab v5 adds lid-raise/smoothing tuning sliders. Commit c918b02.

- [x] **Licence spec §1 LOCKED (Martin, exact phrase, 15:20).** The v2
  nine-field payload contract is frozen; §1 is mirrored to the Pro side as
  a shared contract; any future change needs both repos plus a version
  bump. OpenProject pinned as a community connector (Plus's one connector
  = one standard connector). Commits 12622ad, daffdbb.

- [x] **Pin rules: quoted values with embedded quotes round-trip (B12).** A
  rule whose value contained a double quote (an email subject like
  `re: "urgent"`) rendered unparseable, so the pin editor couldn't re-save an
  untouched rule. Render now escapes quotes and backslashes, the tokenizer
  unescapes them, and unknown escapes pass through so existing rules parse
  exactly as before. Round-trip check added. Mac-verified: 466 passed,
  0 failed.

- [x] **Pick list: the recent-first block gains a horizon (B16).** Journal
  back-fill gave every ever-tracked task a lastConfirmedAt, so a task touched
  once months ago sat above never-tracked "Now" work forever. The block now
  caps at two recency half-lives (default 14 days); older tasks rank
  normally, where their recency still feeds the score. Also: the Pro
  cross-project check evolved to the amendment contract (mustRecreate, Pro
  suite 38/0); criterion 10's mapping-skip reopen recorded as D6-gated; the
  deferral list restored to TODO.md (its original write was a silent
  replace no-op — same bug family as the SyncEngine corruption, caught by
  its absence). Mac-verified: 465 passed, 0 failed.

- [x] **D4 amendment half: the backend now FOLLOWS the journal.** The
  convergence loop replaces detection-only counting: a posted entry whose
  session was trimmed/moved gets updateTimeEntry in place; a backend that
  can't move an entry in place (Xero across projects, AmendmentError
  .mustRecreate) gets delete+recreate with the fresh id recorded; a session
  deleted or fully covered gets its entry deleted and the row parked
  `.retracted` – which re-opens for a clean re-post if the journal side
  later returns; an entry frozen by invoicing (AmendmentError.frozen) parks
  `.diverged`, terminal and counted in Posting health – journal and books
  genuinely disagree and a human reconciles. Unknown errors never guess:
  row untouched, retried next pass. Amendments are capped per pass (20) so
  a mass edit drains gently against rate-limited backends. Xero maps
  movedAcrossProjects → mustRecreate and entryFrozen → frozen. Four new
  transition checks + the trim/delete checks rewritten to amendment
  semantics. Mac-verified: 464 passed, 0 failed.

- [x] **Sensors: Safari tab URLs.** Safari joins the scriptable-browser set
  with its own AppleScript verb ("URL of front document"; Chrome-likes keep
  theirs) – Safari surfaces now carry the tab URL, so URL-based attribution,
  pins and mail detection work there. First use triggers the standard
  Automation prompt. On-device verification pending (compile + suite green).

- [x] **Attribution: OP project pages boost only THAT project's tasks.** The
  in-OP-without-task-id rule trusted the ranking harder on any project page –
  for every task, anywhere. The recognizer now extracts the project slug from
  the URL (`projectHint`), and the boost applies only to tasks whose stable
  project id or slugified title matches; a slug we don't recognise keeps the
  old everyone-boosted fallback (the project may simply not be cached yet).
  Mac-verified: 461 passed, 0 failed.

- [x] **Popover: right-click task menu – Open in backend, Comments.** Each
  pick-list row gains a context menu: "Open in <backend>" opens the task's web
  page via the connector (hidden in standalone mode), and "Comments…" shows
  the timestamped notes stored locally against the task – the read half of
  standalone comment-to-task (notes that couldn't or shouldn't go to a
  backend land there; until now nothing displayed them). WorkTask is now
  Identifiable (keyed by its ref). Mac: build clean, 460/0.

- [x] **Timeline: [+all] window selector.** With a window selected in a
  slice's detail strip, a "+ all" button appears top-right whenever other
  windows in the slice carry the SAME recorded data (app + title + tab URL –
  never the times): one click extends the selection to all of them, ready for
  a single reassign/move. Hidden when it would add nothing; the tooltip
  counts what it will select. Requested live mid-run.

- [x] **Docs-drift pass (reviewer C22–C33).** README: the API key goes to an
  owner-only file in app support, NOT the Keychain (the old claim was
  factually wrong); the architecture bullet stops crediting andeyeTTMac with
  persistence; a Licence line joins first-run. MANUAL.md + site manual:
  Settings now documents the Licence section (key format, tiers, lifetime
  display, error copy), Posting health (stuck + Retry, drifted counts), the
  idle-backfill opt-in, and the currency symbol; the popover pages document
  the billable £ glyph; the time-window pages document the right-click
  billable flags and the flip warning; the keyboard page gains ⌘E and the
  Evidence Card subsection it had drifted behind. Site builds clean (13
  pages). Fresh-reader style throughout – no failure-mode history.

- [x] ** review fixes, batch 4 (reviewer B mediums + lows).** (B4)
  Non-work grace time never bills to the work task: the doNotTrack commit now
  closes the work story at the PEND moment and drops/clips the grace-window
  spans, so changing Steam windows mid-grace can't put games time on a client
  (the leisure-tracking variant resumes the span under the leisure state).
  (B6) An empty task cache (startup, backend refresh) can't auto-stop the
  clock – no candidates, no walkover softmax for doNotTrack. (B8) A pending
  prime (the "you just opened task X" hypothesis) expires after 15 minutes –
  a glance at another task's page no longer outranks a CONFIRMED surface for
  the rest of the run. (B9) Corrections now SUBTRACT from the displaced
  learned belief (source .ranked only): the mistaken association loses count
  weight so sibling surfaces stop inheriting it – LearningStore.correct's
  logic finally has a production caller. (B10) A session's auto-comment draws
  only from its OWN spans – no other-target window titles leaking into
  OP/Xero entry comments. (B11) Same-level email-rule conflicts: newest
  unpinned rule wins (was: oldest, forever). (B14) Pin-scope segments compare
  case-insensitively, matching every PinOp. (B15) Fuzzy match folds
  diacritics ("cafe" finds "Café accounts"). Deferred with context to
  TODO.md: B7 (surface query identity – needs design), B12/B13 (pin editor
  hardening), B16 (recency horizon), C10/C13/C14. Four new checks (B4, B6,
  B8, B9). Mac-verified: 460 passed, 0 failed.

- [x] ** review fixes, batch 3 (Fable reviewer B – attribution/tracker
  HIGHs + sleep-clock guards).** (B1) A manual start now begins span accrual
  at the tap – focus changes made while STOPPED no longer bill their pre-start
  stretch to the new task, and the sensor re-emits the unchanged surface on a
  manual pick so accrual restarts immediately instead of waiting for a window
  change. (B2) Ending a call reopens the live span: same-window work after
  mic-off accrues again (was: silently unspanned until the next window
  change – unbounded loss for single-window workers). (B3) The crash
  checkpoint anchors at the tracker's OWNED live slice (liveSliceOwner/
  liveSliceStart), so provisional switches and sub-grace excursion reverts no
  longer destroy or re-anchor it – a crash mid-grace loses nothing. (C8/C9) A
  wake with the wall clock stepped BACK across sleep (DST fall-back, NTP) no
  longer passes the sleep-grace test and can't attribute the whole sleep; the
  checkpoint clamps end ≥ start. (B5) LearningStore scoring reworked: an
  unmatched feature now costs a CONSTANT instead of a penalty that grew with
  training (heavily-taught tasks lost to never-taught ones on partial matches
  – "got worse with use"); the experience prior applies only on a strong
  match, and hourOfDay is down-weighted 0.15× so an hour coincidence can
  never flip attribution or auto-stop the clock by itself. Four new checks
  pin B1/B2/C8/B5. Mac-verified: 456 passed, 0 failed.

- [x] ** review fixes, batch 2 (Fable reviewer A – tonight's sync
  code).** (A1) The F13 verify sweep now DEMOTES a vanished entry's row to
  `.failed` instead of clearing it – a cleared row plus the synced `pushed=1`
  mirror let the every-pass migration resurrect a stale `.posted` row with the
  dead entry id, permanently cancelling the re-post. (A2) Ledger eligibility
  is FAIL-CLOSED in both stores: only `.failed` (or no row) is retryable, so
  a state written by a newer build blocks re-posting instead of falling
  through a whitelist to a duplicate; pinned by a raw-SQL unknown-state check.
  (A3) A session whose contribution is trimmed to zero (or sub-minute) by
  overlaps now stays PENDING instead of terminally skipped – deleting the
  covering slice later restores its hours to the queue (pinned). Raw
  sub-minute sessions still close terminally. (A4) "Touched since" is now a
  pure REVISION-STAMP comparison (session_stamp on the ledger row) – the
  wall-clock heuristic broke both ways under cross-device clock skew. (A5)
  The inflight ADOPT path mirrors markPushed for pm, so adopted entries can
  be PATCHed/DELETEd by timeline edits. (A6) The verify matcher requires the
  full task+start+duration signature when no entry id exists (duration-only
  matched neighbours). (A7) The divergence scan is bounded: recent rows every
  pass, old rows only when their stamp changes. (A8) Billability flip-close
  now runs BEFORE the backfill floor so old failed finance rows close on a
  flip. FakeBackend gained list-failure + held-entry simulation; new checks
  for hold-the-claim and coverage-lift. Mac-verified: 452 passed, 0 failed.

- [x] ** review fixes, batch 1 (reviewer C – periphery).** Phone:
  todaysTotal now clips at midnight and reads the resolved view; export and
  banked list read the resolved view (C6/C7). TimePeriod: today/thisWeek/last7
  use calendar arithmetic – on DST Sundays an hour of sessions landed in the
  wrong period; London-TZ check added (C15). JournalPrune: rollup ids are now
  DETERMINISTIC (XOR of member ids through the fragment-id namespace) so two
  devices pruning the same day merge to one rollup instead of double-counting
  forever (C16). CheckpointRecovery: a partially-flushed checkpoint now
  promotes only the un-journalled remainder instead of the whole span (C18).
  Sensors: Accessibility trust re-read both ways each poll (C11); idle-poll
  event type no longer force-unwrapped (C12). TimelineMath.latestBlock end is
  the max end, not the last-started's end (C19). EmailSystem fastmail suffix
  anchored (C20). AIAssist: task-id collision no longer fatal (C17); JSON
  taxonomy honest (C21). Mac-verified: 450 passed, 0 failed.

- [x] **A5: posting-health surfacing in Settings.** A "Posting health" section
  appears only when something needs a human: per backend, the count of
  quarantined (`stuck`) entries with a one-click Retry (clears the rows and
  kicks a sync pass – the repair gesture the checks pin), and the count of
  posted entries that have drifted from the journal (D4 detection). Entitlement
  denial copy waits on the cross-repo `requires:` seam wiring. Mac-verified:
  447 passed, 0 failed; full build (incl. andeyeTTUI) clean.

- [x] **F15 + F16: reconnect-backfill age gate; licence re-evaluation without
  relaunch.** (F15) Finance backends now auto-post only sessions younger than
  `financeAutoPostWindowDays` (default 14; 0 = off): after a long-idle
  reconnect (lapsed lease → dead Xero grant → re-subscribe months later) the
  accumulated billable backlog stays VISIBLY PENDING instead of flooding the
  books in one pass – release is a deliberate act, and released backlog posts
  exactly once. pm backends are unaffected. (F16) The licence is revalidated
  hourly off the sync tick (assign-on-change so SwiftUI doesn't churn): a
  lease lapsing mid-run downgrades without a relaunch, and a renewed key takes
  effect the hour it lands. Mac-verified: 447 passed, 0 failed.

- [x] **F13: resurrection reconcile – a posted entry deleted at the backend
  re-posts exactly once.** Cross-device sequence: device A tombstones a posted
  session and deletes its backend entry; a newer edit resurrects the session
  via sync; this replica's ledger still says `.posted` for an entry that no
  longer exists – the journal claims billed, the backend holds nothing (the
  invisible inverse of a double-post). The engine now verifies `.posted` rows
  whose session record was TOUCHED after the row was written (new
  `sessionTouched(_:after:)`, HLC-based, never fires single-device): entry
  present ⇒ row re-dated (quiet until touched again); missing ⇒ row cleared so
  the SAME pass re-posts, exactly once; list failure ⇒ claim survives until
  verifiable. Mac-verified: 446 passed, 0 failed.

- [x] **D4 (detection half): posted-vs-journal drift is now counted and
  surfaced.** Each sync pass compares every posted entry's snapshot
  (posted_start/posted_duration) against the session's CURRENT resolved
  contribution: an edit, a later-arriving overlap trim, or a delete after
  posting makes the backend entry stale – previously silently wrong in the
  books forever. Drift beyond 60 s and retract-worthy (deleted/fully-covered)
  sessions count into BackendReport.diverged and the published
  `AppController.postingDivergences`; detection never re-posts. Amendment
  (updating/deleting the backend entry) is the follow-on half. Mac-verified:
  445 passed, 0 failed.

- [x] **D1: posting/aggregation/export read the overlap-RESOLVED view.** With
  journal sync on, a higher-priority cross-device slice trims what overlapping
  sessions display AND bill – posting the raw span would double-bill the
  claimed minutes. New JournalStore surfaces `resolvedSessions(from:to:)` and
  `resolvedContribution(sessionID:)` (identity defaults keep single-device
  behaviour unchanged; SQLite overrides them when the sync clock is attached);
  SyncEngine bills the contribution (fully-covered sessions close `.skipped`,
  billed nothing) and snapshots posted_start/posted_duration onto the ledger
  row (the D4 drift detector's baseline); the Time-Spent pie (Mac + phone) and
  timesheet export read the resolved view, so displayed seconds == posted
  seconds. Timeline/edit/reconcile paths deliberately stay raw (they operate
  on stored identity). Mac-verified: 444 passed, 0 failed.

- [x] **Licence v2 + entitlement gate; posting robustness (F12/F19/F21/F22/F23);
  sync anti-entropy.** The Fable 5 review-and-build session (implementing a
  prior 23-finding internal review against the v2 designs). One commit
  because the edits interleave inside shared functions; per-feature story:
  (1) LICENCE v2 – nine required fields (v, kid, jti, tier, licensee, issued,
  expires, product, connectors[]), fail-closed decode, multi-kid verifier with
  product match + jti denylist, explicit Comparable tier ladder, LicenseChecks
  rewritten as the spec's acceptance criteria 1–14; `unlocksProBackends`
  removed. Pro generator mirrored (andeyePro/tools/make-license.swift, guard
  rails incl. --lifetime plus-only, no default expiry). (2) ENTITLEMENT –
  BackendRegistry gains BackendEntitlementRequirement + a pure fail-closed
  gate (connectors[] membership AND tier floor) with typed denial reasons;
  gate ships tested but dormant pending the cross-repo `requires:` seam
  change. (3) F19 – PermanentPostError at the TaskBackend seam; permanent
  rejections close `.skipped`-with-reason and the queue PROCEEDS; transient
  failures quarantine `.stuck` after 30 attempts; surfaced in reports +
  lastError. (4) F21/F22 – JournalSyncer re-asserts strictly-newer local wins
  (CloudKit `.allKeys` can revert the server; without re-assert two replicas
  diverge permanently) and pushes in 200-record batches (first sync-enable on
  a mature journal exceeded CloudKit's op cap); MockSyncServer made truthful
  to `.allKeys`. (5) F23 – resolveOverlaps keeps EVERY fragment of a
  middle-split (deterministic child ids via SessionMerge.fragmentID, RFC 9562
  v8-stamped) instead of destroying the smaller side. (6) F12/D3 – `.inflight`
  intent rows written before every create; verify-then-adopt reconcile with a
  60 s settle floor replaces the rollback-delete; crash between create and
  ledger write can no longer double-post. Timeline-edit ledger helpers now key
  by registry.primaryPM (not hardcoded OP). Verified on the Mac:
  `swift run andeyeTTChecks` TOTAL 441 passed, 0 failed (twice).

- [x] **Deflake: ContextRules surface byte-equality check.** Asserted raw
  JSONEncoder byte equality, but key order is nondeterministic – "expected 66
  bytes, got 66 bytes" flake. Now compares canonical (.sortedKeys) encodings;
  the real guarantees (decoded Surface equality + persisted prime firing)
  unchanged.


## 2026-07-07

- [x] **Popover: default-mode styling inverted, billable glyph, enter-to-commit
  comments.** Three related popover fixes. (1) The Reassign/Switch-to header
  wore its blue highlight + (×) revert on "change mode" specifically — but
  change mode is the DEFAULT (`popoverDefaultsToChangeMode` defaults true), so
  the resting default looked like a temporary override and the non-default
  looked plain. Inverted: the styling now follows whichever mode is NON-default
  (blue + the (×) that reverts to the default), driven off `changeMode ==
  settings.popoverDefaultsToChangeMode`, so it's correct BOTH ways — flip the
  setting and Switch-to becomes the plain default while Reassign wears the blue.
  The (×) toggles back to the default (not hard-coded to Switch-to). (2) A cash
  glyph (SF Symbol `sterlingsign`, sized `.system(size: 8)` to match the house
  glyph — the app is UK/£) now shows on tasks whose EFFECTIVE billable state
  resolves billable (task override else project flag else non-billable, via the
  existing `BillableRules.effectiveBillable` / `AppController.isTaskBillable`):
  in each pick-list row (independent of the house glyph — a task can be both)
  and at the end of the running-task display in the header (new
  `AppController.currentTask()`; nil for leisure/uncached refs → no glyph). No
  new billing state invented. (3) Comment field reworked: enter no longer merely
  unfocuses — it COMMITS the draft onto the current tracked time by accumulating
  into `manualNote` (the text the flush path already banks onto the slice),
  flashes the field green (fades out; static brief show under Reduce Motion),
  and clears the input so one slice can carry several comments. Accumulation is
  a pure helper (`CommentRouting.accumulateComment`): distinct comments join
  with "; ", an immediate exact repeat is de-duped, blank input is ignored — so
  no committed comment is lost and none duplicated. The field now holds only the
  UNcommitted draft (no per-keystroke mirror to `manualNote`), which also fixes
  the old cross-slice bleed; on a tracked-task change with a non-empty
  uncommitted draft the field warns red (it would otherwise orphan onto the new
  slice), clearing when entered or emptied. Committed text belongs to the slice
  it was entered on — the flush path banks + clears `manualNote` on the old
  slice, so the next slice starts empty. No journal-schema change;
  segmentation/attribution untouched. New pure checks in `CommentRoutingChecks`
  cover first-comment, ordered concatenation, immediate-repeat de-dupe,
  non-adjacent repeat kept, and blank-ignored; the SwiftUI colour flash is a
  Mac-pass visual check.

- [x] **Live timeline block now tracks in real time and hatches the undecided
  tail (display-only).** Two complaints, both about the live slice disagreeing
  with the menu bar. (1) Realtime: `TimelineView` only rebuilt its slice cache
  on a 30 s timer / journal write / viewport move, so after a "Change to X" the
  menu bar flipped instantly (off `@Published trackerState`) while the live
  block showed the old task for up to 30 s. Fixed with two light, journal-free
  hooks: an `.onChange(of: controller.trackerState)` that flips the live task
  the same instant the menu bar does (and re-folds via `reloadSessions()` only
  when no editor is open), plus a 1 Hz `liveTick` that advances only a `liveNow`
  Date — the `sessions` getter remaps the cached live slice's trailing edge and
  task in memory, no SQLite per second. The tick no-ops while stopped (no
  per-second redraw on an idle timeline) and is PAUSED while any editor is open,
  resuming (the edge catches up) the instant it closes — a periodic re-render
  has stolen editor focus in this view before, so the live edge does not tick
  under an open field rather than gamble that a stable slice identity prevents
  it. (2) Undecided hatch: after a confident switch the display follows the
  new task instantly, but the journal slice stays provisional — revertible to
  the prior task — until the run holds past `sliceFloor = max(switchGrace, 60)`.
  That existing `pendingSwitch` state is now surfaced read-only as
  `SessionTracker.pendingSwitchSince` / `graceEndsAt` (and
  `AppController.liveGraceRange`), and the timeline cross-hatches the sub-range
  `[since, min(now, graceEnds)]` of the live slice — growing with the clock,
  solidifying (hatch clears) the moment the switch commits, vanishing on a
  revert. A settled task, a reverted excursion, a fresh start (manual pick /
  idle-resume) and a pending non-work *stop* are deliberately NOT hatched — the
  smallest honest mapping onto real provisional state, inventing no new
  segmentation. Nothing here writes to the journal or changes attribution /
  segmentation: purely how the timeline draws and when it refreshes. New
  `SessionTracker` checks (projection non-nil across a provisional switch,
  clears on commit and on revert, follows a non-default Switch Buffer via
  `sliceFloor`, and stays nil for a pending non-work stop); the SwiftUI drawing
  itself is verified on the Mac.

- [x] **"Move N windows to →" now works on the live block's earlier windows
  (2026-07-05 hardware test).** On a long single-task morning, selecting a
  window in the timeline strip and clicking a task under "Move N windows to
  →" did nothing. Root cause: the live block folds earlier contiguous
  same-task journal rows into ONE displayed slice (`timelineSessions`), but
  the reassign split only a single row — the just-committed live tail
  (`commitLiveSlice` returns one `.max(by: end)` session). Any selected
  window living in an earlier row fell outside that row, so
  `TimelineMath.split`'s clip emptied, `splitAndReassign`'s guard returned,
  and nothing moved. Fix: `splitAndReassign` (AppController) now gathers
  EVERY same-task journal session overlapping the selected ranges
  (`journal.sessions` is true-overlap) and splits each, in one undo step, via
  a new pure `TimelineMath.splitAcross` (returns only the rows a range
  actually changes, so an unselected same-task row between two picked windows
  is left alone). Live callers still commit the tail first, so its own
  windows are a real row and tracking stays continuous; the write path bumps
  `journalRevision` as before, so the timeline refreshes. The per-window
  Evidence Card "Wrong? file as" reassign goes through the same method, so it
  is fixed too. Hard invariant made airtight (review-caught): ONLY selected
  time ever changes task — the old sub-minute "absorb tiny fragment" step
  could flip up to 60s of UNSELECTED time onto the target at a range edge,
  and silently swallowed a genuinely-selected sub-minute window; a fragment
  now merges into its neighbour only when they already share a task, so an
  honest short sliver is kept rather than misattributing a second of tracked
  time (`minPiece` retired). New splitAcross + split checks in andeyeTTChecks
  (windows in two different rows both move; only the rows the ranges hit
  change; an unselected sub-minute edge tail stays put; a selected sub-minute
  window moves).

- [x] **Popover display-layer polish: Reassign wording, house icon, comment
  bar moved down, fewer hint lines, no duplicated clock, idle-backfill button
  opt-in.** Six display-only changes, none touching segmentation, attribution
  or the journal. (1) User-facing "Change to" → "Reassign" throughout the
  popover (header mode toggle + its ⌘T tooltips, the switch-list header, the
  Settings default-mode toggle) — makes clear the action relabels the WHOLE
  running session, not a switch; the internal `changeMode` /
  `changeCurrentTask` / `popoverDefaultsToChangeMode` symbols and its default
  (still `true`) are untouched, wording only. (2) `PopoverView.taskRow` now
  shows the same `house` glyph as SpentView/TimelineView/ReviewView for a
  local-only task — it was the one list missing it. (3) The manual-note
  comment bar (bubble.left + TextField, gated on
  `CommentRouting.noteInputVisible`) moved out of the header, where it
  competed with the running-task/certainty line, down to a new `commentBar`
  just above the footer icon row. (4) Two always-on hint lines under the
  switch list ("type a comment…", "type to search all N tasks") are gone;
  their info now lives in `.help()` tooltips on the filter field ("Search
  your tasks") and the comment field ("Add a comment on this time — ↵ when
  done") — same info, on hover only, less vertical clutter. (5) The header's
  elapsed-time text is gone from both the pinned and unpinned tracking rows
  (confirmed `MenuTitle.text`/`refreshTitle` always render elapsed time in
  the menu-bar title while `.tracking`, so nothing is lost) — the unpinned
  row keeps its "N% certain" indicator, the one thing NOT already in the menu
  bar; the pinned row's badge is now the whole line. (6) The "worked on X
  while away?" idle-gap button is now gated on a new `Settings.
  offerIdleBackfill` (default `false`, alongside `idleBackfillWindowSeconds`)
  in addition to its existing pending-gap/window check, with a Settings
  toggle ("Offer to log time you were away") that also enables/disables the
  duration stepper — off by default, so the prominent blue button doesn't
  appear unless opted in. New `AndeyeSettings` "defaults" check for
  `offerIdleBackfill == false`; the rest is layout-only and verified on the
  Mac.

## 2026-07-06

- [x] **Evidence Card keeps the story straight after a correction (honesty
  fix, 2026-07-05 hardware test).** Correcting an attribution used to rewrite
  history: "Apple 71% certain, learned" became "BECAUSE you categorised this
  today → Amazon" with Apple gone from the candidates entirely — "that's the
  only thing I ever thought it could be". Core now snapshots the displaced
  belief the moment a pick lands (`Attributor.recordDisplaced`, called from
  `confirm`/`assign` before the sticky is written; stored in
  `displacedByCorrection`, keyed by — and sharing the exact lifetime of — the
  sticky it belongs to: pruned at day rollover, removed on forget, restored
  wholesale by the forget-undo, never persisted). The explanation payload
  carries it as `AttributionExplanation.priorToCorrection`, and the card says
  it in three places: a "before your correction: Apple 71% (learned rule)"
  history line under BECAUSE; the candidates line labels the correction-born
  winner "– your correction" and RETAINS the displaced belief at its
  pre-correction score instead of silently dropping it; and the forget
  preview appends "– what it thought before your correction" when the
  fallback lands back on the displaced winner (it already did mechanically —
  now it says so). Only the FIRST displacement per context is kept, so
  re-correcting can't overwrite the machine's original belief with the
  intermediate pick, and nothing is captured when the engine already agreed.
  `confirm`/`assign` gained a defaulted `tasks:` parameter so ranked beliefs
  snapshot with their real score; SessionTracker/AppController call sites
  pass their task lists. New CorrectionHistory suite in andeyeTTChecks
  (snapshot captured on pick, surfaced in the payload, original belief held
  across re-corrections, fallback preview names the pre-correction winner,
  history dies with its correction).

- [x] **Multi-backend seam + billable flag (task_002, unblocks andeyePro/Xero).**
  The posting path is no longer one-backend-one-slot. A connector-agnostic
  `BackendRegistry` (Sources/andeyeTTCore/BackendRegistry.swift) holds N
  `(TaskBackend, class)` entries — `class` is an extensible role, `pm` and
  `finance` today — and `AppController.register(backend:id:class:)` is the
  documented seam andeyePro calls to add Xero alongside OpenProject. The
  journal gains a per-(session, backend) posting ledger
  (pending/posted/failed/skipped + backend entry id; `posting_ledger` table
  in SQLiteJournalStore, protocol methods on JournalStore) whose
  (session, backend) key is the idempotency key: retries only update their
  own row, one backend failing never blocks another, and a session can be
  posted to OP while pending to a finance backend. A one-time, per-row-
  idempotent migration maps every legacy `pushedToOP`/`opTimeEntryID` row to
  a posted ledger row against the OP id, so the ledger-driven sync can never
  double-post upgraded history; the legacy fields survive as the primary-pm
  mirror the timeline PATCH/delete and summary keep reading. SyncEngine now
  fans out per registered backend: pm = owns()-scoped confirmed time
  (exactly the old behaviour with one pm registered); finance = ONLY
  effectively-billable time, deliberately bypassing owns(); personal
  `.local` tasks reach no backend of any class, ever. Billable model in Core
  (Billing.swift): project-level Bool + task tri-state
  (inherit/billable/non-billable), DEFAULT NON-BILLABLE, persisted in a
  user-ownable billing.json keyed by stable backend-scoped project ids (the
  OP conformer now captures the project id from the work-package project
  href; title-keyed fallback migrates to id keys on the first refresh after
  ids are known). Flips are prospective-only via a per-flag `since` gate;
  the Time Spent legend gets right-click billable toggles and the cascade
  alert reports manually-set tasks left behind plus the stranded uninvoiced
  hours; one currency-symbol Settings field defaults from
  `Locale.currencySymbol`. andeyeTTChecks adds Billing + MultiBackendSync
  suites (ledger conformance for both stores, migration losslessness,
  class filtering, cascade/left-behind, stranded-hours arithmetic, and the
  mandatory two-backends-of-different-classes concurrent scenario), and the
  SyncEngine/idempotency suites were reworked for the report-based,
  failure-isolated engine.

- [x] **Four hardware-test UI fixes: contrast, pin-editor confirm placement,
  Evidence Card wrap/stability + fallback forget, Rules Ledger delete
  discoverability.** All from Martin's 2026-07-06 hardware pass on the
  Evidence Card / un-learn / rules-ledger phase (2026-07-05 merge).
  (1) Contrast — the pin editor's blue/grey Components strip, the pinned
  glyph in the Evidence Card and Rules Ledger, the "away" icon and the
  Change-to label all read `Color.accentColor` (the user's system accent,
  often a dark systemBlue) straight onto the popover's dark vibrancy
  background. New `AndeyeColors.highlight` (Sources/andeyeTTUI/
  AndeyeColors.swift) is one brighter, cyan-leaning constant used for
  TEXT/glyph foreground in place of those raw accentColor reads;
  decorative fills/strokes (calendar highlight, timeline selection) are
  untouched. (2) Pin editor — the confirm (↵ Pin) button sat left of the
  hamburger and the ✕ dismiss, so the instinctive rightmost click hit
  dismiss; reordered so ✕ dismiss → hamburger → ↵ Pin, confirm now
  rightmost (PopoverView.pinEditor). (3) Evidence Card — `becauseLabel`,
  the pinned-rule label, the fallback-preview line, `seesLine`,
  `candidatesSection` and the grain-ladder row text all truncated
  (`lineLimit`) instead of wrapping; switched to
  `.fixedSize(horizontal: false, vertical: true)` throughout. The
  truncate→wrap change made row heights variable, and SwiftUI's implicit
  animation on that height change was visibly disturbing neighbouring
  rows on click ("mangled" per Martin) — `.animation(nil, value: ...)`
  on the unlearn block, the grain ladder (keyed on `grainCount`) and the
  filtered-task list (keyed on `pickedTask`) turns that off. The
  `.help` text and the diagnostic dump in `probeEmailSender()`
  (AppController.swift) said "ghost"/"not captured on this site"; the
  card's ghost SEGMENTS already render `display: "not captured"` at the
  Core level (ContextIdentity.swift) — only the tooltips needed the
  plain-English "not captured on this window" wording, now consistent
  between the pin editor and the card. (4) Fallback forget — the card
  only let you forget the memory CURRENTLY firing; the live "would then
  fall back to…" preview offered no way to remove that fallback itself,
  so an old wrong rule sat there as a standing possibility even while the
  current attribution was correct. New `Attributor.forgettableWithout` /
  `AppController.forgettableWithout` (mirrors `explainWithout`'s
  snapshot-forget-restore, but previews `forgettable` instead of
  `explain`) surfaces a second "✕ forget that fallback too" button on the
  same preview line, reusing the existing `forget`/undo machinery
  unchanged. (5) Rules Ledger — per-row delete already existed
  (`deleteRule`, undoable) but Martin couldn't find it; the ✕ is now a
  red `trash` icon (was a plain secondary `xmark.circle`), gated behind a
  `confirmationDialog` ("Forget this rule?"), with an inline "Deleted … ·
  Undo" banner after removal so the correction doesn't depend on knowing
  ⌘Z exists. Container has no macOS — Mac verification pending (see
  TODO.md).

- [x] **Menu-bar jiggle killed for real — measured width, not assumed
  glyph metrics.** Martin verified on hardware that the logo still moved
  after the 2026-07-03 fix (figure-space pad + `.monospacedDigit()`).
  Root cause: that fix assumed U+2007 FIGURE SPACE renders exactly one
  tabular digit wide once `.monospacedDigit()` is applied — true on some
  fonts, not guaranteed on all (the OpenType `tnum` feature retargets
  digit advance widths; the figure space's own advance is baked in at
  font-design time and isn't necessarily touched by the same feature), so
  the padded single-digit second could still differ in width from its
  two-digit neighbour by a hair, and the logo dragged with it every
  second during the first minute of tracking. Fix: stop trusting glyph
  metrics — `MenuTitle.sizingTemplates(elapsed:certainty:showPercent:)`
  (Sources/andeyeTTMac/AppController.swift) returns every digit-count
  `MenuTitle.text` can emit within the SAME bracket (seconds-under-a-
  minute / minutes-under-an-hour / hours, plus the widest 3-digit percent
  suffix when shown); `AppController.menuSizingTemplates` publishes them
  alongside `menuText`; RootScenes' MenuBarExtra label overlays them,
  `.hidden()`, behind the real `Text` in a `ZStack` so the container is
  sized to whichever candidate SwiftUI actually measures as widest — the
  logo's position now depends on real layout, not on an assumption about
  a specific character's advance width. Crossing INTO the next bracket
  (59s → 1m, 59m → 1h 00m) is still left unreserved, same call as before:
  a real, infrequent width change, not the 1 Hz jiggle. New check
  ("sizing templates cover every digit-count text() can emit within a
  bracket", Sources/andeyeTTChecks/MacChecks.swift) asserts every
  template is at least as wide, in characters, as anything `text()` can
  actually produce in that bracket. NOT COMMITTED — Martin verifies on
  the Mac first.

- [x] **Front-page copy now lives in one editable file + "Light by design"
  section** (site/src/content/copy/home.md, content.config.ts,
  index.astro). Every owner-editable sentence on the landing page – hero,
  demo intro/caption, flowsheet nodes, privacy claims, tier panels, footer
  – is commented YAML frontmatter in home.md; the page interpolates it at
  build time (a define:vars COPY island feeds the strings the demo script
  needs). Edit the file, rebuild, done – no code touched. Deliberately NOT
  extracted: the demo's simulated inbox/tab content (coupled to the demo's
  state keys; noted in the file header). New "Light by design" section
  between privacy and Community/Pro makes the honest climate case: no
  server, no per-minute cloud-AI inference, a handful of local rules in
  the Mac's idle time – no CO2 numbers, no competitor names, and the
  human-footprint-per-hour claim deliberately left out as unsurvivable
  under scrutiny.

- [x] **Demo correction per Martin's review** (site/src/pages/index.astro).
  Timeline and time pie moved OUT of the fake Mac screen into two separate
  always-visible boxes beneath it (the in-screen andeye window and its
  view flip removed; pie back to full size); the mail reading view now
  keeps the real inbox in the left third with the reading pane opening
  beside it (mini preview-rail deleted); the demo heading is now
  "It's {Weekday}, {time}" live, and the timeline box header carries the
  same live clock as the demo's menu bar.

- [x] **Site demo rebuilt: fixed-size windows, one andeye Time view at a
  time, live local clock, second-person story v2** (site/src/pages/
  index.astro). The Mail window never changes size again: reading view is
  a preview-rail + pane grid inside a fixed-height window, click-outside
  returns to the inbox – and the root cause of the original "window grows"
  bug is fixed properly (`[hidden]` loses to author `display` rules per
  the CSS cascade; a `[hidden]{display:none!important}` reset now wins).
  The andeye Time window shows the timeline OR the pie, switched by
  orange-underlined chrome buttons, like the real app. Story: client is
  now Sarah Coleman (a person) who runs a bakery, saying yes to "the
  spring retainer – where do I sign?"; research is the first Chrome tab
  and its own tracked project; all three tab drawings are fresh,
  render-verified compositions (kitten-and-yarn video page, bakery site,
  sector-outlook article). The whole demo anchors to the visitor's local
  clock (heading daypart, menu-bar clock, email times, timeline start;
  no-JS fallbacks kept). Sitewide: no ALL-CAPS anywhere (andeye is
  lowercase), "Your timesheet writes itself in three moves" as a
  hover/click flowsheet with a reserved detail panel, privacy split into
  four click-accordions (gist headline + dig-in body, "Only what you
  approve ever leaves" now its own entry), Community/Pro as tabs with a
  sliding orange underline, eyebrow mini-logos that draw on and wink per
  section, the red→green certainty phrase set in an actual gradient,
  menu-bar logo/clock gap closed, waitlist mailtos → time@andeye.com.
  Adversarial review: one major (the [hidden] cascade bug), two nits, all
  fixed; needs a Mac-browser eyeball for the reserved panel heights.

- [x] **Manual: winking logo header, "Getting help" page, standing rules**
  (site/src/components/AndeyeSiteTitle.astro, site/astro.config.mjs,
  site/src/content/docs/manual/{getting-help,index}.md, CLAUDE.md). The
  manual's Starlight header now carries the andeye mark as a live canvas –
  draws itself on at load, winks occasionally (eyelid close, visibility-
  and reduced-motion-aware), and clicks back to the one-page app; geometry
  is a verbatim port of AndeyeLogo.swift via index.astro with a
  keep-in-sync comment. New "Getting help" page: GitHub Issues/Discussions
  walkthrough for everyone (written for non-developers), time@andeye.com as
  the andeyePro support channel, and an honest paragraph on why
  person-to-person support is one of the things Pro pays for. CLAUDE.md
  gained the manual's standing rules: keep up with the app but never at the
  cost of user-friendliness; comprehensive but concise; written for the
  fresh reader (no X→Y change history, no self-flagellation); code-drawn
  illustrations, never screenshots. Adversarial review: clean bar two nits
  (em-dash comments, opener register), fixed.

## 2026-07-05

- [x] **Site demo back to basics: second-person story, andeye Time window
  on the demo desktop** (site/src/pages/index.astro). The demo drops the
  named-career persona (the freelance designer) for a career-neutral
  second person — "Your Tuesday morning, 9:41" — since any career label
  forces the visitor to identify with someone else, and the paying
  audience (people who invoice; the Xero tier) only needs to recognise
  their own desk: an inbox, a client saying yes to *the proposal*
  ("where do I sign?"), the accountant, a mid-certainty research tab,
  one honest kitten. The timeline + pie stop being a separate section
  below the Mac frame and become the **andeye Time window on the demo
  desktop itself** — truer to the product and it restores the everything-
  visible-at-once layout the four-window grid had broken. Three work
  windows on top (Mail, Chrome, Pages proposal doc; design app and chat
  removed), andeye Time full width beneath, never a tracked surface and
  excluded from the idle hint pulse. Billable framing made honest and
  explicit: only client work is billable (Accounts = "your books",
  Anthropic = "reading", Kittens = "break") with a live "Billable so
  far" total under the legend, and the caption lands the money hook:
  "the billable slice is your invoice, and you never wrote anything
  down". All three browser-tab drawings plus the proposal document are
  fresh compositions (the kitten is now mid-pounce after a ball of yarn
  in a video player — nothing shared with the earlier head-and-box art).
  Astro build green; adversarial review clean bar one stale comment,
  fixed.

## 2026-07-04

- [x] **Context rules UI phase: the Evidence Card, un-learn, and the Rules
  Ledger** (2026-07-03-context-rules-ux.md, Option A + grafts, MVP items
  4/5/7 of §6; Core items 1-3 landed earlier WIP 2e6f784). New
  `EvidenceCardView` (andeyeTTUI) — one view, two hosts — shows BECAUSE (the
  source that fired, with the matched rule's/pin's provenance), a live
  `[✕ forget]` / `[✕ suppress]` with the "would then fall back to…" preview
  rendered BEFORE the click, the `sees:` evidence line (ghosts for
  not-captured fields, never hidden), and a `Wrong? file as` fix flow with
  the grain ladder rendered as labelled full-width rows (↑/↓ move the
  grain, Once/Remember/Return/⇧Return/Always). Reachable from the popover's
  new why-caption (⌘E, inline expansion under the header) and from the
  timeline's per-window panes (replacing the old monospaced `detailText`
  dump). Retired the silent `learnEmailRule` call from `Attributor.confirm`/
  `assign` per spec §5.4 — a plain correction no longer writes a durable
  rule behind the user's back; the card and the popover's new post-pick
  grain footer propose one instead, undoable like everything else via the
  existing `UndoStack`. New Rules Ledger window (Settings ▸ Email → task
  matching ▸ "Context rules…") lists every learned + pinned rule grouped by
  task with provenance (origin, created, fired, last fired) and a per-row
  delete. Core additions: `Attributor.learnEmailRule` gained an explicit
  level/value/pinned/origin path (the auto-detect default stays for direct
  callers); `ContextIdentity.cardDefaultGrainIndex` (the card's own
  conservative default — domain for an org, address for shared webmail,
  narrowest-available when no correspondent captured — deliberately NOT the
  pin editor's most-specific-available `defaultGrainCount`);
  `SegmentKind.emailMatchLevel`/`Segment.emailMatchValue` (the grain→rule
  commit mapping, unlike `pinPredicate` treats the system row as a real
  EmailRule level so "Always: everything in Gmail" is representable); new
  `RulesLedger.grouped` (pure sort/filter). 13 new checks (CardDefaultGrain,
  EmailGrainCommitMapping, RulesLedger suites) plus 6 existing checks
  updated whose scenarios depended on the retired silent call (confirm/
  assign now teach a rule only when the check calls `learnEmailRule`
  directly, matching the new UI-driven flow). Deferred to later polish
  (spec §6, unchanged from the diagnosis): first-learn/first-fire toasts +
  screen-share suppression, site recipes beyond Gmail, review-queue grain
  footer, multi-correspondent checkbox expansion, ledger row opens the
  card, bulk-forget/export. UNVERIFIED — no Mac available to build/run
  `andeyeTTChecks` or eyeball the SwiftUI; every signature was grepped
  against the landed Core, not compiled.

- [x] **Landing: Martin's demo refinements re-applied natively, original
  voice restored.** The mechanics from the directed iterations (story cast
  with priya@example.com, click-to-open emails, four designer windows,
  macOS traffic-light focus with dimmed background windows, no autoplay,
  working menu bar [winking mark · elapsed · one-word task], line-art Chrome
  tabs incl. the still kitten, clickable timeline + pie, orange hero, varied
  red→green certainty) kept; the copy pass reverses the drift Martin flagged
  ("the copy went downhill fast"): the hero lede is back to the original's
  cadence ("attributes your time to tasks by itself &ndash; on your Mac,
  never phoning home"), the demo intro carries the eye-follows/winks line
  with the corrected red/green, and the privacy section returns to the
  original's three tight blocks ("the eye answers to the person it watches",
  "Learning stays local", "Your rules, on your disk") with the single false
  claim patched honestly ("the only thing that ever leaves is a finished
  time entry you approve"). All three bake-off treatments preserved at
  docs/site-treatments/ for the record. Build green, 10 pages.

- [x] **Ambitick removed from the codebase entirely (migrations are done).**
  Martin: he wants the old working name gone, kept only as a private note.
  The data-folder and keychain migrations have run on the only machine that
  matters, so the backward-compat code was now dead and safe to drop:
  `AppSupport.directory` no longer moves a legacy `Ambitick/` dir (just
  returns the `andeye` home); the four migration checks in MacChecks are
  replaced by two plain data-home checks; `make-app.sh` drops the
  `ambitick-dev` keychain-migration block and the `Ambitick.app`/process-name
  handling; `install-andeye.command`, `APIKeyStore`, the integration scratch
  subject, CLAUDE.md's hard-rules and entitled-build's keychain reference are
  all cleaned. 
  NOTE: removing the auto-migration means a machine still holding
  Ambitick-era data would start fresh rather than adopt it - there are none,
  but it's no longer a safety net. Checks not run here (no Swift toolchain);
  run `swift run andeyeTTChecks` on the Mac (net -2 checks in the suite).

- [x] **Landing accuracy fixes, manual leads with auto-tracking, image
  strategy.** From the adversarial accuracy review (no blockers): the OBSERVE
  copy drops the absolute "that is the whole feed" claim (the AGPL-visible
  `MicMonitor` makes an exhaustive "this is everything we watch" statement
  false), so the page is selective without over-claiming - the untested
  mic-in-use sensor is left unmentioned rather than advertised, since naming
  it reads as eavesdropping on calls; "what a message was about" tightened to
  "its subject line"; "files in your home folder" corrected to andeye's own
  folder.
  The manual now leads with Auto-tracking and attribution (sidebar + Overview
  both reordered; the Overview opens on "there is no start button" - the
  automatic experience is the starting point). Added a manual image strategy
  spec (docs/superpowers/specs/2026-07-04-manual-image-strategy.md): where
  images live (src/assets, Astro-optimised), PNG-for-UI/SVG-for-diagrams,
  light+dark for key shots, alt-text and a staleness manifest, and the split
  between Mac-captured screenshots and agent-authorable diagrams.

- [x] **Finished the Ambitick residual sweep.** The 2026-07-03 rename passes
  left reader-facing mentions behind: the README's H1 area carried a "the
  original working name was Ambitick" parenthetical (removed - public
  baggage), the README cited the old `2026-06-10-ambitick-design.md` spec by
  name (dropped), two `github.com/aqueum/ambitick` test-fixture URLs in
  ContextRulesChecks (→ `andeyePro/andeyeTT`), and a stale "(previously
  'Ambitick Time')" TODO parenthetical (removed). Genuinely load-bearing
  strings (the legacy Application-Support dir migration in AppSupport /
  MacChecks, the `ambitick-dev` keychain path in make-app.sh, the OP scratch
  subject) and dated historical specs/plans are deliberately kept. Local
  Xcode `xcschememanagement.plist` still names old schemes - regenerates on
  the next `xcodegen`, not hand-edited.

- [x] **Landing page major revision: story-driven demo, honest certainty
  colours, honest privacy claim, real timeline + pie, hover-reactive CTA.**
  Five coherent changes to `site/src/pages/index.astro` (still fully
  self-contained, CSP-safe, reduced-motion respected, body never scrolls
  horizontally):
  - *Certainty colour fixed to the app's truth.* The old copy/demo said the
    tint was "grey when unsure, amber when sure" — wrong. `MenuTitle.colour`
    blends `#FF3B30` (systemRed) → `#34C759` (systemGreen) linearly by
    certainty, so the mark is RED when unsure and GREEN when sure. The demo's
    `certRGB` and the caption/how-it-works copy now match.
  - *Story-driven demo.* Replaced the generic clickable surfaces with a
    freelancer's Tuesday morning. An email client with three correspondents —
    Maren Vale (a rebrand/website client → "Maren · rebrand"), Priya the
    accountant (→ "Accounts · Q2 invoices"), and Anthropic (→ "Claude
    integration") — plus a browser with three tabs: Maren's staging site and a
    localhost tab (work) and a kitten video (an honest, non-billable break).
    Click any email or tab and andeye attributes the time to the job that
    correspondence/tab belongs to; the clock restarts, the eye winks, the tint
    blends red→green by confidence. Auto-plays a scripted loop until first
    interaction, then hands over.
  - *Real timeline + real pie below the demo,* fed by the demo's accumulated
    attribution and growing as the story plays. Slices/wedges are coloured by
    project via the app's HSB(hue, 0.55, 0.85) palette (AppController.colour);
    the pie is a donut-with-a-hole (time-by-project) with a legend that flags
    the break as not billable.
  - *Hover/focus-reactive CTA subtext.* One line under the buttons that changes
    on hover or keyboard focus: a build-from-source line for "Star on GitHub",
    a plain-English "a ready-to-download app is coming, we'll email you" line
    for "Join the waitlist", and a neutral default otherwise.
  - *Privacy claim reframed honestly.* Dropped the false "nothing ever leaves"
    framing. New centrepiece: the raw signal (what you looked at, page
    contents, correspondents, attribution, learning, pin rules, the SQLite
    journal) never leaves your Mac and andeye Ltd receives nothing; the ONLY
    thing that travels is the finished time entries you approve, to your own
    OpenProject / Xero. Also fixed the meta description and the OBSERVE step.
  `npm run build` green at 10 pages; node_modules removed after build.

- [x] **Landing page: the "Watchful" treatment (Fable-authored original) is
  the `/` route.** Martin picked it from the three-way bake-off (Instrument /
  Ink / Watchful — all three authored by Fable 5 subagents just before the
  session credit limit; the drafts were never committed, which mis-attributed
  the page to the later session that wrapped it). The hero is a playable
  menu-bar demo: the living andeye mark (verbatim AndeyeLogo.swift geometry —
  draw-on, eyelid-close wink), clickable app surfaces, attribution following
  focus. This is the ORIGINAL treatment; the demo-refinement iterations
  Martin directed later (story cast, macOS traffic-light focus, clickable
  timeline/pie, red→green certainty fix et al.) live on the `opus4.8` branch,
  to be merged or re-applied here. `npm run build` green, 10 pages.

## 2026-07-03

- [x] **Contributor-facing governance: CONTRIBUTORS roster, CLA
  plain-English summary, CONTRIBUTING explanation.** Adds CONTRIBUTORS.md
  (the signing roster CLA.md already references), a plain-English summary
  box at the top of CLA.md (additive; the binding clauses are unchanged),
  and a CONTRIBUTING.md rewrite that links CLAUDE.md and explains honestly
  why the CLA exists (AGPL and the App Store are incompatible, per the VLC
  precedent, so dual-licensing is what lets one codebase be the community
  app and the iPhone/Pro app). Note for review: the CLA still has no
  explicit governing-law clause.

- [x] **Root CLAUDE.md: orientation map for agents and humans.** Module
  layout (lowercase `andeyeTT*`/`andeyeApp` targets, UpperCamelCase types),
  build/check/run commands, the load-bearing legacy-string and
  keychain-identity rules, and the TODO/CHANGELOG conventions.

- [x] **Website scaffold: Astro + Starlight in `site/`, built for Cloudflare
  Pages.** One Astro project serves both the marketing landing page (`/`, a
  swappable placeholder until the chosen treatment is productionised) and the
  full manual (Starlight at `/manual`, search on). The manual is seeded by
  splitting MANUAL.md into eight pages (getting started, auto-tracking &
  attribution, pinning, the menu-bar popover, the time window, settings,
  sync & safety, keyboard). Static output, no SSR adapter; `npm run build`
  green (10 pages). `site/README.md` carries the exact Cloudflare dashboard
  settings (root directory `site`, build `npm run build`, output `dist`).
  Design decisions recorded in docs/superpowers/specs/2026-07-03-website-design.md.

- [x] **A pinned Gmail surface can now reach the grain ladder — reopen a
  root site pin and it opens INTO the ladder, system grain selected.**
  Martin: "Going into various emails does not show [the ladder]" — one broad
  mail.google.com (or legacy) pin covers every email, so each one showed the
  📌 chip; reopening a `.components` pin deliberately suppressed the ladder
  (3d2d122's round-trip guard), so the ladder was unreachable exactly where
  it's most wanted: "the whole site is pinned, narrow it to this
  correspondent". Root URL pins on an email surface now reopen into the
  ladder with the system/site grain selected by its OWN index (so a
  reordered ladder can't misindex; re-committing untouched rebuilds the
  identical root PinScope, id reused). Deep path pins and app pins still get
  the classic strip — they have no ladder equivalent.

- [x] **Module-level case rename: `AndeyeTT*`/`AndeyeApp` → `andeyeTT*`/`andeyeApp`.**
  Brings every SwiftPM target/product/directory in line with Martin's
  lowercase-module convention (module `andeyeTTCore`, matching the sibling
  `andeyeProBackends`/`andeyeProChecks` targets in the Pro repo) — only the
  identifiers change, Swift TYPE names stay UpperCamelCase
  (`AndeyeLogo`/`AndeyeLogoImage`/`AndeyeScenes`/`AndeyeApp` the `App` struct
  all untouched). Renamed: `Sources/AndeyeTTCore` → `andeyeTTCore`,
  `AndeyeTTMac` → `andeyeTTMac`, `AndeyeTTUI` → `andeyeTTUI`, `AndeyeTTStore`
  → `andeyeTTStore`, `AndeyeTTPhone` → `andeyeTTPhone`, `AndeyeTTChecks` →
  `andeyeTTChecks`, `AndeyeTTIntegration` → `andeyeTTIntegration`,
  `AndeyeApp` → `andeyeApp`; Package.swift targets/products/dependency
  strings and `swift run` comments follow; `ios/project.yml`'s three
  `product:` lines and every `import AndeyeTT*` across Sources/ and
  ios/Sources (~50 files) now read lowercase; `scripts/make-app.sh`'s
  `--product`/bin-path lines follow. **Pro-side fallout: the Pro repo's
  imports must change too** — `import AndeyeTTCore` etc. now fail to
  resolve; every Pro file importing this package needs `import
  andeyeTTCore`/`andeyeTTMac`/`andeyeTTUI`/`andeyeTTStore`/`andeyeTTPhone`.
  **First Mac build after pulling this needs `rm -rf .build`** — a
  case-insensitive filesystem caches build products keyed by directory name,
  and `AndeyeTTCore`/`andeyeTTCore` collide there; stale cache from the old
  case causes confusing build errors otherwise. Also run `cd ios &&
  xcodegen` to regenerate `andeye.xcodeproj` from the updated `project.yml`
  (the pbxproj itself was left untouched here — it's generated and has
  Martin's uncommitted local edits).

- [x] **Ambitick mention purge — the residual-name sweep the 4e7a393 module
  rename deferred.** Every remaining "Ambitick"/"ambitick" mention now says
  the right new name: check fixture strings and their assertions updated
  together (menu-suffix check is now `"andeyeTT design"` → `"21m andey"`;
  the learned-titleToken expectation follows the lowercased `"andeyett"`;
  the regex-operator fixture is `("andeyett", "and.?y")`; case-insensitivity
  checks keep case-differing needles), example URLs/segments moved from
  `aqueum/ambitick` to `andeyePro/andeyeTT`, temp-file scratch names to
  `andeyett-*`, code doc-comments and the Settings caption ("21m andey")
  swept, TODO/.gitignore/entitled-build/overnight-memo updated
  (entitled-build now carries the rename plan's `com.andeye.mac` /
  `iCloud.com.andeye.mac` IDs and the real `AndeyeJournal` zone), the
  2026-07-02 taskref-remote plan's file paths follow the renamed tree, and
  the three dated 2026-06 Ambitick plans/specs keep their filenames+content
  as historical record with a one-line "now andeyeTT" gloss. LEFT IN PLACE
  deliberately: the legacy data-dir migration strings (`Ambitick/` support
  dir in AppSupport + MacChecks — they must match old installs), the
  pre-rename quit/retire lines in make-app.sh and install-andeye.command,
  make-app.sh's existing `~/ambitick-dev.keychain-db` (renaming would mint a
  new identity and void TCC grants), the OP integration scratch-WP subject
  (reuses the live WP; rename plan says leave), the `ambitick` Mac build
  user in the overnight memo (real account name), CHANGELOG history, and
  ios/andeye.xcodeproj/project.pbxproj (stale generated `AmbitickCore/
  Store/Phone` productRefs — regenerate on the Mac with `cd ios && xcodegen`
  from the already-correct project.yml rather than hand-editing).

- [x] **Pin editor grain ladder — pin an email by correspondent, domain or
  subject, visually, no typed expressions (pin-editor slice of the
  context-rules-ux spec).** Martin: "I don't want to have to pin every single
  email, but … I do need the ability to pin them by correspondent email
  address and domain … a really intuitive interface for this." Deliberately
  the pin-editor slice ONLY — no Evidence Card, no un-learn, no rules ledger,
  no toasts (those stay open, see TODO). When the popover's pin editor
  (Components mode) opens on a surface with email evidence, it now shows the
  broad→narrow email ladder (Gmail ▸ harborlane.example ▸
  r.naismith@harborlane.example ▸ "subject") instead of the bare URL/app
  strip, fed by `ContextIdentity` (landed WIP 2e6f784) via a new
  `AppController.pinEmailIdentity()`. Same interaction as the proven strip:
  click a segment, ← wider, → narrower, ↵ commits — but clicking a segment
  SETS that single grain (Option B's model) rather than accumulating a
  prefix. Mapping: correspondent/domain/subject grains commit as a single
  `PinRule.expression` leaf (`sender is <addr>`, `sender contains <domain>`,
  `subject contains <normalised text>`); the system/site grain (and any
  plain, non-email surface) keeps the existing `.components(PinScope)` root
  pin — "this whole site" is exactly what that already means, regardless of
  where the user's `emailMatchOrder` setting puts it in the ladder. Ghost
  ("not captured") segments render greyed, italic and unclickable; ← / → skip
  over them via a new pure `ContextIdentity.steppedGrainCount`, so a ghost is
  never reachable at all, matching the spec's "rows are never hidden, their
  absence IS the coverage signal" without ever letting one become the
  selection. Reopening an email-grain pin round-trips: a system/site pin
  reopens in the classic Components strip (it IS a plain PinScope pin); a
  correspondent/domain/subject pin reopens in Expression mode with the rule
  rendered back to text (deliberately not reverse-mapped onto the ladder —
  the spec explicitly allows this as the simplest correct behaviour). +8
  checks (`isEmailGrain`/`pinPredicate` mapping incl. ghosts, `defaultGrainCount`,
  `steppedGrainCount` incl. ghost-skipping and both-edges clamping). Not
  verified on-device (no Swift toolchain in this environment — Mac-side
  smoke test needed: open the pin editor on a captured Gmail message, confirm
  the ladder renders and each grain commits/reopens correctly). Out of scope
  (see TODO): the Evidence Card (see-why, un-learn, live fallback preview),
  first-learn toasts, the Rules Ledger, and the shared-webmail caution tint
  on the strip.

- [x] **Gmail correspondent capture is live again — async, deadline-bounded,
  one probe in flight (capture layer of the correspondent-attribution
  programme).** The 2026-07-03 diagnosis (a90fe90) found capture had been off
  since the 6-30 freeze-revert (5439a83): every live signal carried nil
  correspondents/subject, so the whole email-rule system (EmailRule ladder,
  sender/domain pins, email-keyed stickies) was dead code at runtime. Fix per
  the diagnosis's fix design: new `EmailCaptureEngine` (AndeyeTTMac) replaces
  every `NSAppleScript` round-trip — main-thread-bound, the actual cause of
  the freeze — with an `/usr/bin/osascript` SUBPROCESS run off a background
  queue, hard per-call deadline, watchdog kill. `SensorHub.poll()` emits the
  plain `.focus` signal immediately (never blocks) and only on a
  surface-change onto a chrome-like browser sitting on a KNOWN, recipe'd mail
  host (`EmailSystem.hasRecipe`) kicks a capture off fire-and-forget, one in
  flight at a time (a request while busy is dropped, not queued). The result
  comes back as a new `SensorEvent.focusEnrichment`, applied RETROACTIVELY by
  `SessionTracker.applyEnrichment` to the still-open span — but only if the
  surface is still the one the probe was captured for (`Surface(signal:)`
  equality); a probe that outlives the user's next focus change is dropped
  silently, never mis-tagging whatever is open now. The diagnostics "Probe
  email sender" button now shares the same engine
  (`EmailSignalProbe.buildReport()`, run via `Task.detached` so it no longer
  risks even its own AX-crawl blocking main). +9 checks (3 SessionTracker
  retroactive-enrichment scenarios incl. the stale-surface drop; 6
  EmailCaptureEngine pure gate cases — the `osascript`/`Process` execution
  itself is impure and browser-dependent, so it needs the on-device soak the
  diagnosis explicitly calls for: "191 green checks did not catch a
  main-thread stall" was the 6-30 lesson). Out of scope here: the Evidence
  Card / un-learn UI (context-rules-ux spec, Core layer landed WIP in
  2e6f784, unverified, UI phase not started) and the base poll's own
  tab-URL/title AppleScript hazard (TODO.md — a separate, lower-probability
  instance of the same freeze class, left for its own fix).

- [x] **Menu-bar jiggle killed; wink is now an eyelid close on task change.**
  Martin: "when seconds are counting, the logo is jiggling" — the logo image
  was a fixed 28×18 canvas all along; the 1 Hz seconds text ("41s"→"42s")
  changed width in proportional digits and the right-anchored status item
  dragged the logo with it (identical in the dot era, just invisible on a
  12 px circle). Fix: `.monospacedDigit()` on the menu Text plus a leading
  FIGURE SPACE (U+2007, exactly one tabular-digit wide) on single-digit
  seconds, so 9s→10s doesn't reflow either — no reserved width for minutes.
  Wink retargeted per Martin: tracked-task change winks, minute tick doesn't
  (was the reverse); stopped→tracking is a start, not a switch, so no wink.
  And the wink itself is redesigned from whole-mark vertical squash to a
  true eyelid close: left side and both eye corners pinned, top lid comes
  down a lot, bottom lid rises a little, meeting in a slightly-positive ‿
  line — closed control points fitted numerically (least-squares of the top
  lid onto the reversed raised bottom lid; max lid gap 1.6 SVG units against
  the 17-unit stroke, so they render as one line). AndeyeLogoChecks rewritten
  for the new invariants (corners/left side fixed, monotone lid travel,
  lids-meet gap bound, gentle-sag bound); MacChecks covers the pad.

- [x] **iOS timeline is now DRAWN, matching the Mac's (321 checks green,
  iOS simulator build succeeded).** Martin: "why did you ditch the beautiful
  and highly functional timeline from the mac app and replace it with a
  regular list?" — TimelinePhoneView's List replaced with a Canvas timeline
  mirroring the Mac look: horizontal time axis with adaptive hour ticks +
  labels (`TimelineMath.tickStep`, width-aware so labels never collide on a
  phone), coloured slice bars with task labels (same PhonePalette scheme as
  the pie/Now views), gaps as gaps, a red "now" line, and the live slice
  growing at the right with the Mac's zig-zag torn edge (same SliceShape
  geometry). Touch model: pinch-zoom anchored on the fingers + drag-pan,
  both clamped to today (`TimelineMath.clampViewport`, pure + checked);
  opens framed on the latest block like the Mac (`latestBlock`), "Day"
  toolbar button zooms back out. Tap a slice → read-only detail card (task,
  start–end, duration, live badge); edits stay Mac-side. Drawing factored
  into `ios/Sources/TimelineCanvas.swift` (no UIKit, no controller) and
  visually verified: rendered headless on the build Mac via ImageRenderer
  at 8 h / 24 h / 1 h zooms, light + dark, and inspected — matches the Mac
  bar. +4 TimelineMath checks (viewport clamp, tick step).

- [x] **Menu-bar icon now renders Martin's real andeye mark, not invented
  geometry.** He supplied the actual logo (assets/brand/andeye.svg +
  andeye-logo.afdesign, moved from repo root, 3-line README added);
  AndeyeLogo.swift now hardcodes its path verbatim — four cubics, translate
  applied, normalised to a unit-width box preserving the 365:235 aspect.
  Pupil/eyelid machinery dropped (his mark has none); the arc-length draw-on
  reveal stays, and the wink is now a vertical squash of the whole mark
  toward its centre (width preserved) so it can never mangle the curves.
  AndeyeLogoImage strokes at 17/365 width, round caps/joins, ~18pt tall ×
  ~28pt wide; certainty tint and AppController trigger plumbing untouched.
  Checks rewritten (contiguity, closed loop, reveal monotone/linear, squash
  bounds, aspect); geometry rendered to PNGs at 360×232 and 36×24 and
  visually verified against the SVG. 321 checks green.

- [x] **Full rename: the package is `andeyeTT` (317 checks green, iOS
  simulator build succeeded).** Martin's call — the core carries the brand
  for future adjacent apps. Targets/products: AmbitickCore→AndeyeTTCore,
  Store→AndeyeTTStore, Mac→AndeyeTTMac, UI→AndeyeTTUI, Phone→AndeyeTTPhone,
  App→AndeyeApp, CoreChecks→AndeyeTTChecks, Integration→AndeyeTTIntegration;
  public types AmbitickScenes→AndeyeScenes, AmbitickSettings→AndeyeSettings,
  version enum Ambitick→Andeye; CloudKit zone AmbitickJournal→AndeyeJournal
  (never minted, so free). Brand refs in comments/UI strings swept to
  andeye; the LEGACY data-folder migration strings keep "Ambitick" verbatim
  (they name the old on-disk dir). install-ambitick.command →
  install-andeye.command (still quits pre-rename installs). ios/project.yml
  package andeyeTT. Announced to the PRO vibe first (its product references
  need the new names on next sync); the Mac folder ../Ambitick and build
  user stay until Martin renames the folder. Clone URL in docs now
  andeyePro/andeye (Martin transfers/renames the GitHub repo).

- [x] **andeye logo in the menu bar — draw-on, certainty tint, minute wink
  (317 checks green).** The coloured dot is now the brand mark: an ampersand
  drawn as one continuous stroke whose tail closes into an eye (andeye =
  "&eye"), pure bezier geometry in `AmbitickCore.AndeyeLogo` (unit box,
  platform-free, 12 checks: contiguity, arc-length reveal linear in t, lids
  as the final draw phase, pupil under the lids, wink squash/clamps).
  `AndeyeLogoImage` (AmbitickMac) strokes it into the ~18 pt status-item
  image, tinted by the existing `MenuTitle.colour` certainty pipeline — the
  colour still means what it meant. On launch the mark hand-draws itself
  (t 0→1 over ~1.2 s, the end closing into the eye, pupil popping in last);
  each time the displayed tracked minute ticks over the eye winks
  (shut→half→open, ~360 ms). Both are fire-and-forget Task frame loops —
  no continuous animation timer; the 1 Hz title refresh is untouched.
  Visual result unverified until Martin rebuilds (geometry is check-proven,
  plus contrast-rendered off-Mac).

- [x] **iOS v1 feedback pass — Mac-popover feel + the Time pie/timeline
  (305 checks green).** Martin's on-device notes, all six: the "andeye"
  title is gone; share moved into a single hamburger menu with Settings;
  the huge stop button shrank to a small red stop control beside a compact
  name + elapsed row (the menu-bar popover feel); tapping the tracked task
  is now a no-op (`start` returns on `tracking?.task == task` — before, it
  restarted the timer on every tap); a tap still SWITCHES, but long-press
  offers "Re-label current timer as this" — new
  `PhoneController.relabelCurrent(to:)` moves the RUNNING slice onto the
  task keeping its start (checkpoint follows, nothing banked). And the
  Mac's coolest views came over: a LIVE mini-pie toolbar icon (Canvas +
  Core's PieGeometry) opens a Time page — donut by project, tap a wedge
  for its task ring, Today/Week picker, label-keyed selection — plus a
  read-only timeline list of the day's slices. New PhoneController data
  accessors `spentNodes(from:to:)` (live slice included, boundary-clipped,
  no app level) and `bankedSessions(from:to:)`. Five new checks: tracked-tap
  no-op, relabel keeps start + updates checkpoint + banks nothing, relabel
  idle no-op, spentNodes grouping, bankedSessions ordering.

## 2026-07-02

- [x] **Session-sticky categorisation — your word holds for the day (300
  checks green).** Martin's 23:27 report: composing an email, every
  leave-and-return re-ran the inference ladder and an older email rule
  re-took the slice for the wrong project. Now any explicit assignment
  (popover pick, review assign, timeline edit, do-not-track) records a
  `SessionSticky` keyed on the email's normalised subject (re:/fwd:
  stripped — a draft's window title mutates while typing, the subject
  doesn't), falling back to correspondent set, then focus surface. In the
  ladder it sits directly below explicit pins and above everything
  inferred (URL recognition, email rules, primes, ranker), expires at the
  local day boundary (the durable email rule the same assignment teaches
  takes over), and the why-panel names it. 10 checks incl. the verbatim
  report scenario.

- [x] **iOS engine moved into the checked package (290 checks green).**
  PhoneController left ios/ (where nothing compiles it until Xcode) for a
  new platform-neutral `AmbitickPhone` target: SwiftUI import dropped for
  Combine, data home + clock injectable. Eight new checks cover the manual
  tracker's behaviour — sub-30s taps discarded, slices journalled, live
  slice surviving app death and resuming on relaunch, switch = stop+start,
  local-task dedupe, fuzzy pick list, todaysTotal, CSV export. Only the
  SwiftUI shell in ios/ now waits for a machine with Xcode. Fixed en route:
  the check harness drove async suites from a semaphore-blocked main
  thread, which deadlocked any check hopping to the MainActor — now
  top-level await (SE-0343).

- [x] **Licence landed: AGPL-3.0 + CLA (Martin's call, 15:03 BST).** LICENSE
  is the verbatim SPDX AGPL-3.0-only text; CLA.md is an ICLA-style agreement
  granting andeye Ltd rights broad enough to dual-license the proprietary
  App Store builds; CONTRIBUTING's pending section now states both; README
  gains a Licence section. The staging kit (docs/licensing-staging/) deleted
  itself in this commit. Remaining before the repo flips public (WP 223):
  Martin reviews the CLA text and the CLA enforcement check gets wired.

- [x] **UndoStack extracted to Core (282 checks green).** The pure stack +
  grouping semantics behind the global ⌘Z (LIFO, group-bundles-to-one-entry
  with reversed replay, nested groups folding into the outermost, empty
  groups pushing nothing) moved from AppController into
  `AmbitickCore.UndoStack` with 5 checks; the controller keeps the sounds,
  notification and published count. First of the three review-flagged
  AppController extractions.

- [x] **PieGeometry extracted to Core + label-keyed pie selection (277 checks
  green).** The Time Spent donut's pure geometry (slice-angle layout, polar
  normalisation, radial band hit model, metrics) moved from SpentView into
  `AmbitickCore.PieGeometry` with 10 checks, sharable with the iOS pie.
  Fixes the parked fable2 review finding: hover/pin selection was positional
  (`project(i)`/`task(i,j)`) into a re-sorted nodes array, so a background
  reload while a wedge was pinned could silently retarget the pin — selection
  is now keyed by node labels and resolved against the current array each
  render (a vanished node clears the pin instead of retargeting; regression
  check covers the re-sort survival).

- [x] **Duplicate reconcile generalised beyond OP (267 checks green,
  11c6d0a).** `RemoteTimeEntry` is a real Core struct with String ids (was a
  typealias to OP's Int-id shape); `ReconcileAction` is backend-neutral
  (String taskID, RemoteEntryID survivor/deletes); OPBackend converts at its
  edge; journal matching goes through `task.backendTaskID`, so the duplicate
  scan works for any backend that can list entries. Closes the TODO left
  open by the TaskRef.remote migration.

- [x] **Rename phase 1 executed: the app IS andeye now (261 checks green).**
  Data home migrates `Application Support/Ambitick` → `andeye` via a checked
  one-shot MOVE (fresh-install / move-with-contents / one-shot semantics all
  covered); debug log → andeye-debug.log; make-app.sh builds andeye.app
  (bundle id com.andeye.mac, "andeye Dev" signing identity, quits/retires
  pre-rename installs); window titles + popover copy renamed; README/MANUAL
  swept (repo URL + module names deliberately keep the working name — see
  the rename plan's phase 2). NOTE FOR THE NEXT BUILD: new bundle id + new
  signing identity = macOS treats it as a new app — Accessibility and
  Automation get granted ONCE more.

- [x] **Seam: `supportsTaskComments` capability (255 checks green).** Xero
  Projects has no task-comment endpoint; rather than erroring per note, the
  controller now skips comment-to-task for backends that declare false (the
  note still lands on the time entry). OP declares true.

- [x] **`TaskRef.remote(String)` — GUID backends are first-class (255 checks
  green).** Executed docs/superpowers/specs/2026-07-02-taskref-remote-plan.md
  : additive third case, so
  every existing journal row / pin / email rule / primed surface decodes
  byte-identically — the wire format is now FROZEN by checks. The seam speaks
  String task ids (OP converts at its edge); backends declare `owns(_:)` and
  the SyncEngine skips un-owned eligible sessions silently (an .op session
  can never push to Xero — it waits for its own backend). `is_op` column
  keeps its name, means "remote/pushable". Recognizers return TaskRefs.
  AIAssist's reply grammar accepts GUID strings and now resolves ids through
  the live task cache — which also fixes a latent bug where a hallucinated
  id fabricated a nonexistent `.op` task. DuplicateReconcile stays OP-only
  (TODO'd). SEQUENCING: this ships one Community release before any GUID
  backend mints `.remote` refs (older builds can't decode the new case).

- [x] **Open-core app shape: the SwiftUI layer is now the `AmbitickUI`
  library; `AmbitickApp` is a three-line Community wrapper.** New
  `AmbitickScenes.body(controller:)` (@MainActor SceneBuilder) carries the
  MenuBarExtra + all windows; the private repo's Pro executable becomes the
  same thin wrapper plus paid-backend registration. `AmbitickMac`/`AmbitickUI`
  exported as library products for the pro package to depend on. Behaviour
  identical (bindings on the Time windows constructed explicitly — a static
  SceneBuilder has no `$controller`). the build bridge now cleans the remote
  Sources tree before syncing (tar never deletes, so moved files ghosted).
  245 checks green.

- [x] **Controller sync wiring + CloudKit transport skeleton (245 checks
  green).** New `escalateOrigin` on the journal protocol: deliberate user
  actions promote a slice's cross-device authority (timeline edit/reassign →
  `edited`, idle-gap claim → `manual`; auto tracking stays `auto`); promotion
  re-stamps + dirties (it must sync), downgrades are refused no-ops.
  `AmbitickSettings.journalSyncEnabled` (default OFF — store behaviour is
  byte-for-byte pre-sync until flipped); on enablement the controller mints a
  persisted device id, restores the HLC clock state (persisted per stamped
  mutation, so stamps stay monotonic across a wall-clock regression), excludes
  the crash-checkpoint row, and runs the idempotent backlog stamp.
  `CloudKitSyncTransport` (Mac layer, `canImport(CloudKit)`) maps
  SessionRevision ⇄ CKRecord in one custom private-DB zone — thin by design,
  Core's merge stays the authority; inert until the entitled build exists.

- [x] **Licensing rail (5 checks, 244 total green).** Core `License` /
  `LicenseTier` (plus/pro/premium/enterprise; Community = no licence, fully
  functional) with offline Ed25519 verification of `AMBI1.<payload>.<sig>`
  keys (dot-separated JWT-style; base64url payload is canonical sorted-keys
  JSON). Checks cover tamper (payload-swap upgrade attack), keygen (foreign
  private key), expiry vs perpetual, garbage inputs, whitespace tolerance.
  The production PUBLIC key is embedded; the private key + generator live
  only in the pro staging area (gitignored) pending the ambitick-pro repo.
  Settings gains a Licence section (paste key, tier/licensee/renewal status,
  problem line — an expired key explains itself rather than silently
  downgrading); controller revalidates on key change.

- [x] **RemoteEntryID widened Int → String (Xero-ready; 239 checks green).**
  The seam's entry id is now String (OP: ints, Xero: GUIDs); `OPBackend`
  converts at its edge and surfaces a non-numeric id as an error instead of
  silently no-opping. `Session.opTimeEntryID` widens with a custom decode so
  every pre-widening journal row (Int in the JSON) still reads — covered by a
  legacy-decode regression check — while encoding always writes the String
  form. DuplicateReconcile keeps Int on the OP-API side and compares via
  String at the journal boundary.

- [x] **SQLite journal becomes a sync replica (15 checks, 237 total green).**
  The sessions table now carries the revision meta (HLC triplet, origin,
  deleted, dirty) beside the row; `SQLiteJournalStore` conforms to
  `RevisionStore`. With a clock attached, every JournalStore mutation
  re-stamps + dirties (markPushed included) and deletes become travelling
  tombstones; without one, behaviour is byte-for-byte pre-sync (hard deletes,
  no stamping). All reads filter tombstones. The live crash-checkpoint row is
  sync-excluded (never stamped, never uploaded, hard-deleted).
  `stampAllUnstamped` is the one-shot enablement migration (start-ordered,
  idempotent). clearDirty is HLC-matched so an edit landing mid-push stays
  queued. New conformance suite runs against BOTH stores, plus an end-to-end
  check where a SQLite replica and an in-memory replica converge through the
  mock server.

- [x] **Sync orchestration: `JournalSyncer` + `SyncTransport`/`RevisionStore`
  seams (5 checks, 222 total green).** The replica sync cycle (pull → HLC
  receive → record-LWW apply → push dirty → clear) is pure Core, driven in
  checks by a `MockSyncServer` that reuses the same `SessionMerge` LWW.
  Proven scenarios: two offline replicas converge to identical raw sets and
  views; conflicting whole-record edits resolve to the later HLC on both
  sides; tombstones travel and a later edit resurrects; push echoes are
  idempotent (no duplicates, nothing left dirty, no re-push of clean
  records); a dirty local that wins LWW survives the pull and propagates.
  Remaining for real sync: SQLite adoption of `RevisionStore` + controller
  stamping (origin/HLC per mutation path), then the thin CloudKit transport.

- [x] **Sync foundation: design doc + pure-Core HLC/merge engine (11 checks,
  217 total green).** Decision (Martin): multi-master journal from day one —
  iOS-only users have no Mac to own it. New
  `docs/superpowers/specs/2026-07-02-sync-design.md`: every device holds a
  full SQLite replica; the raw revision set is the synced truth; overlap
  resolution is a DERIVED, deterministic view (never persisted/pushed — the
  one way LWW could diverge); one backend-pusher lease per account. Code:
  `HLC` hybrid logical clock (monotonic tick, causality-preserving receive,
  1 h drift cap), `SessionRevision` (hlc + origin + tombstone),
  `SessionMerge` — record LWW (newer delete beats edit, newer edit
  resurrects) + the overlap ladder (edited > manual > auto; ties by HLC;
  middle overlaps keep the loser's larger side; covered slices surface
  deleted). Convergence checked commutative and arrival-order independent.
  CloudKit is a thin transport adapter later (needs the Apple signing
  identity).

## 2026-07-01

- [x] **Menu clock: excursions no longer wear the old slice's elapsed ("11m
  Studi").** Since the 06-27 banked-under-count fix, the clock took
  `max(now − liveSliceStart, banked+running)` — correct for the task that owns
  the open slice, wrong during a grace-pending switch, where the display
  already follows the NEW task but `liveSliceStart` still spans the OLD task's
  slice: the menu bar paired the new task's name with the old task's clock.
  New `SessionTracker.liveSliceOwner` (the outgoing task until commit); the
  controller only applies the live-slice clock when the displayed task owns
  the slice, so an excursion shows its own visit time (what would post if the
  switch commits — the documented semantics). Found live by Martin right after
  the fable2 build swap; root-caused from the debug log (healthy pipeline,
  display-only). 1 new check; 206 green.

- [x] **Efficiency pass (from the fable2 whole-repo review).** (1) The 1 Hz
  `elapsedText` republish is now change-gated like its neighbours — it fired
  `objectWillChange` on the shared controller every second while tracking,
  re-rendering EVERY open window (timeline, pie, settings) at 1 Hz, 24/7; the
  single largest energy leak found. (2) Durable recency no longer decodes the
  whole sessions table once a minute: new `JournalStore.latestEndByTask
  (excluding:)` aggregates in SQL (`json_extract` + `GROUP BY` + `MAX(end)`).
  (3) `markPushed`/`assign` read-modify-writes now hold the store lock across
  the whole critical section (an off-main sync could interleave with a
  main-actor edit of the same row between their two lock acquisitions —
  last-writer-wins data loss). (4) Dead `refreshTick` state removed from
  Timeline/Spent (it forced a redundant extra body invalidation per poll).
  (5) Timer tolerances on the 60 s refresh and both 2 s pollers so the OS
  coalesces wakeups. 2 new store-conformance checks; 205 green.

- [x] **Timesheet export (standalone slice of Rank 9).** New pure-Core
  `TimesheetExport`: a period's sessions as RFC-4180 CSV
  (`date,start,end,duration,project,task,comment`) or day-grouped Markdown with
  per-day + grand totals. Settings ▸ Maintenance gains an "Export timesheet"
  row (period picker + Copy CSV / Copy Markdown via the clipboard); works with
  or without a connected backend — the standalone way OUT of Ambitick for
  invoicing. 4 new checks (203 total green).

- [x] **Backend seam (TODO Rank 9 core): `TaskBackend` protocol; OpenProject
  moves behind `OPBackend`.** New Core protocol `TaskBackend` (task list, time
  entries, task comments, `taskURL`, capability flag `supportsActivities`) plus
  `BackendPageRecognizer` (task-page/URL/title recognition for attribution).
  `OPBackend` wraps `OPClient` and owns every OP quirk — the startTime-422
  fallback moved here from `SyncEngine` (and now persists across syncs instead
  of resetting each run, since the controller holds one backend instance);
  `SyncEngine` is backend-agnostic. `Attributor` consults a recognizer (default
  = OP built from `instanceHost`, injected by the backend on connect) instead
  of calling `OPURLParser` directly. `AppController` talks only to
  `any TaskBackend`; standalone = nil backend (explicitly NOT a silent no-op
  sink: with no backend no SyncEngine exists, so nothing can be marked pushed
  without going anywhere). `RemoteEntryID`/`TimeActivity`/`RemoteTimeEntry`
  typealiases mark the spots that widen when Xero lands (entry ids become
  String GUIDs — one-line alias flip, compiler-guided). UI: activity picker
  hides for backends without activities; "open in OP" URLs come from the
  backend. 199 checks green; behaviour-preserving by design.

- [x] **Batch (drafted by subagents, integrated serially): pin grammar, smarter
  search, ladder-reorder UI.** (1) Expression pins gained `from`/`sender` (match
  the email correspondents), `subject`, and `any` fields; `PinField` is now
  multi-valued (a leaf matches if ANY value matches) and bare keyword text spans
  correspondents + subject too — so `from contains "harborlane.example"` pins all
  mail to/from a company. (2) Task filter is learning-backed: `LearningStore.
  learnedValues(for:)` feeds `FuzzyMatch.filter`, so typing "voting" finds the
  task you always work in a voting window even when its OP subject never says the
  word (gated at substring-or-better so weak subsequence noise can't leak in).
  (3) A Settings "Email → task matching" section reorders the specificity ladder
  via chevrons. Also confirmed the Review window already creates named local
  tasks. 199 checks pass; the two Core patches are fully unit-tested, the two UI
  bits need an on-device look.

## 2026-06-30

- [!] **Email capture REVERTED same day — it froze tracking.** The capture below
  ran a synchronous Chrome AppleScript/JS call on the 2s sensor-poll thread; in
  Gmail every email switch is an email URL, so every poll blocked, the sampler
  stalled, focus switches went unrecorded and time lumped onto the last task. Pulled
  the call from the hot path (the engine stays, inert). Must be redone async/off-main.
- [x] **Email auto-learner goes live: capture populates correspondents** — the
  sampler now, on a surface change to a recognised webmail MESSAGE, runs the page
  recipe and attaches the external correspondents (sender+recipients minus self,
  via the "me" heuristic) and subject to the `ActivitySignal`. It fires only on an
  email-URL surface change — non-email focuses pay just a host check, so no
  hot-loop cost (the per-poll URL read was already there). With the engine below,
  this makes it end-to-end: correct an email's task once → mail from that
  org-domain (or that person, for shared webmail) auto-attributes. `EmailSignal.
  subject(fromTitle:)` parses the subject off the tab title (unit-checked). NEEDS
  on-device validation (perf on thread-switch + that correspondents populate).
- [x] **Email auto-learner engine (Core, wired, zero live change yet)** — the
  correction→rule learner that drives email attribution. `ActivitySignal` now
  carries optional `correspondents` + `emailSubject` (optional → old journalled
  signals still decode, round-trip-tested). `Attributor` gained learned
  `emailRules` + the `emailMatchOrder`: a confirmation on an email surface learns
  a rule conservatively (an org domain generalises to the whole company; a shared
  webmail address — gmail/outlook/icloud/… — stays per-person), and a matching
  rule then auto-attributes via a new `.emailRule` source (caps 0.95, below a pin
  / OP-URL), resolved most-specific-first through the user's ladder. Rules persist
  in `emailrules.json`; the why-panel explains the new source. Because the Mac
  capture doesn't populate `correspondents` yet, production behaviour is
  unchanged — but the whole engine is unit-tested (learn-by-domain, shared-webmail
  per-person, non-email signals ignored). 191 checks pass. Next: the perf-gated
  Mac capture that fills `correspondents` and flips it live.
- [x] **Settings file is now wipe-proof — the OP URL survives any rebuild** —
  root-cause fix for the recurring "rebuild deleted my OP URL" bug. The settings
  decoder fell over whenever ONE field couldn't be read (twice now: a renamed enum
  rawValue), because `try decodeIfPresent(...) ?? default` rethrows a *throw* (it
  only catches nil); the whole file then failed to load, collapsed to an
  empty-URL default, and the next save persisted that over the real file. Now
  EVERY field decodes through a `lenient` helper that swallows its own throw and
  falls back to that field's default — so a renamed/removed/type-changed field can
  never take the file (or the OP URL) down again. Regression test covers a renamed
  enum, a wrong-typed field, and a good field together. NB you'll need to re-enter
  the URL once (the already-damaged file has it blank); after that it persists.

## 2026-06-29

- [x] **Email→task precedence ladder (user-editable backbone)** — the shared
  most-specific-wins ladder both the auto-learner and the pin will resolve
  through. New pure, unit-checked Core: `EmailMatchLevel` (emailSystem <
  senderDomain < sender < subject, general→specific), `EmailContext`, `EmailRule`
  (learned or pinned; a pin beats a learned rule at the same level), and
  `EmailMatcher.match` (most-specific matching level wins; subject matches by
  substring so RE:/Fwd: prefixes don't break it). The order persists in settings
  (`emailMatchOrder`, tolerant-decoded) so the user can retune it. 185 checks pass.
- [x] **Gmail sender extraction: channel + recipe found, typed foundation** —
  on-device probing settled the approach. Chrome keeps its renderer accessibility
  tree off (AXManualAccessibility didn't wake it — two ~65-node reads), so the
  channel is **page JavaScript over Apple Events**. A blanket `[email]` query was
  polluted by the 100+ inbox-list `.yP` rows Gmail keeps in the DOM; the validated
  recipe is **`.gD` = open-message sender, `.g2` = recipients**, and since Gmail
  names your own address "me" the external counterparty falls out cleanly (e.g.
  the broker's `@harborlane.example`). Shipped the typed foundation: `EmailSystem`
  (host detection + per-system selectors), `EmailSignal.Party` /
  `counterparties` / `domain` (pure, unit-checked), and
  `EmailSignalProbe.frontBrowserParties` (recipe-driven), all surfaced in the
  Settings ▸ Diagnostics probe (now shows System / Sender / Recipients /
  Counterparties / domains). 184 checks pass. Still to wire: sender/counterparty
  into the ActivitySignal + learner + pin `from` field, validation/self-heal, and
  more providers.
- [x] **Email-sender signal: backlog item + Gmail AX probe (prototype)** — logged
  the root flaw (capture only sees app/title/url; a Gmail tab exposes subject +
  account but never the sender, the most useful "which task" key) as a defined
  TODO: sender as a captured signal + learner feature + pin `from` field, subject
  trumps sender in specificity, a new `any` field spanning all fields, done across
  all major email systems via smart generalisations with self-learning (system- or
  AI-derived per-client hints). Started the prototype: `EmailSignal.addresses`
  (pure email extraction, unit-checked) + `EmailSignalProbe` (bounded AX walk of
  the front browser's focused window) behind a Settings ▸ Diagnostics button that
  reports the email-like strings and their AX roles and copies them to the
  clipboard — so we design the real extractor from live data. AX walk is Mac-only;
  needs an on-device run. 182 checks pass.

## 2026-06-28

- [x] **Pin editor AI mode (#11 final phase)** — a fourth hamburger entry for
  windows whose own app/title/url don't say which task they are. New Core builders
  (unit-checked): `AIAssist.pinRulePrompt` assembles a prompt from the captured
  fields + an editable guidance box (pre-seeded `defaultPinAdvice` nudging toward
  a stable pattern over a volatile title), and `AIAssist.cleanRuleReply` strips
  fences / trailing prose from the answer. The prompt is shown scrollable and
  auto-copied; the pasted reply is parsed by the existing PredicateParser into an
  ordinary **editable Expression rule** (↵ applies → review → ↵ pins), or shows
  the parse error. A **Fix with AI** button on an Expression parse error hands the
  failed rule into this mode. Controller gained `currentSurfaceFields()` and a
  generic `copyToClipboard`. 181 checks pass; UI flow needs an on-device check.
- [x] **Keyboard shortcuts across every surface + parity audit** — an Explore
  inventory confirmed every action already has a mouse path. Added ⌘-shortcuts to
  the daily-driver surfaces and put each chord in the control's tooltip and in
  MANUAL.md's rewritten Keyboard section. Popover: ⌘T flip Switch/Change, ⌘P pin,
  ⌘. stop, ⌘R resume, ⌘Z back, ⌘Y Time, ⌘U Review, ⌘, Settings, ⌘Q quit, ↵ in the
  filter picks the top task, ⌘↵ claims the idle gap. Time window: ⌘\ flip
  timeline/pie; timeline ⌘[ /⌘] pan, ⌘−/⌘+ zoom, ⌘B block, ⌘0 today, ⌘⌫ delete in
  editor; pie ⌘1–4 period, ⌘⇧O OpenProject-only, ⌘⇧C calendar, ⌘[ /⌘] month.
  Review: ⌘D do-not-track, ⌘⇧C copy prompt, ⌘↵ apply response, ↵ assigns top task.
  Settings/Review forms stay on standard macOS Tab/Space/arrow navigation. Builds
  clean; the key-window shortcut firing still needs an on-device check.
- [x] **Calendar click snaps to the preset width; drag = custom** — a plain click
  re-anchors the active preset's width on the clicked day (Today → that one day,
  Week → that day's week, Last 7 days → 7 days ending on today's weekday, Month →
  that month). Dragging across days, or shift-clicking, makes an arbitrary
  contiguous custom range instead. (Refines the entry below.)
- [x] **Calendar: selectable day-ranges + pie keeps full height** — the calendar
  is now an arbitrary day-range selector: click one day, drag across a span, or
  shift-click to extend (origin = the current selection's start). The pie shows
  exactly the selected days; a hand-selection that happens to equal a preset
  re-lights that preset button (new pure `TimePeriod.matching`, unit-checked),
  otherwise the picker reads "Custom". Also reworked the layout so opening the
  calendar no longer forces the pie up: the pie fills the full height on the left,
  the legend + calendar share that height in the right column, and the total /
  OpenProject-only controls overlay the pie's empty bottom-left corner. Dropped
  the **Yesterday** preset and shortened "This week"/"This month" to "Week"/
  "Month". 179 checks pass.
- [x] **Pie highlight-calendar + no timeline focus-ring** — the whole timeline
  bar had picked up a blue selection ring (`.focusable()` draws a focus effect);
  added `.focusEffectDisabled()` so arrow-key focus stays but the ring is gone.
  Then implemented the pie's calendar: a new pure `TimePeriod` enum in Core with
  an **anchorable** `range(anchor:now:)` (so a period can be viewed on any prior
  date, not just relative to today), unit-checked. A new `MonthCalendar` grid
  sits bottom-right below the legend: it highlights the days in the shown range,
  pages months (future months disabled), rings today, and re-anchors the pie on
  a tapped day — "This week" jumps to that day's whole week, "Last 7 days" to the
  7 days ending on today's weekday. The Today/Yesterday/… picker moved from the
  top of the window to below the calendar, and the calendar is closeable (✕ →
  a compact reopen button). 178 checks pass.
- [x] **TODO batch (drafted by subagents, integrated serially)** — 7 items, each
  built + checked + committed: Time-window titles per view (Timeline / Time Pie);
  pie "OpenProject only" + total moved bottom-left; optional per-pin **priority**
  override (Advanced) in the pin editor; **auto-prime a new local task** to the
  current window so its time files correctly from the first second; why-panel
  **weight controls** (boost/always via `Attributor.learnSurface`); a **true
  global ⌘⇧L** away hotkey (Carbon, fires from any app); **arrow-key slice
  navigation** in the timeline (←/→ move, ⇧ extends, Return edits). 175 checks
  pass. (Two items not shipped: the pie highlight-calendar draft conflicted with
  the OP-only relocation and had a malformed test — reverted, needs a focused
  pass; named-local-tasks-from-Review the agent didn't draft.)
- [x] **Reconnect on the URL alone when a key is stored** — the connect button
  required the always-blank key field; now "Connect" reuses the stored key.
- [x] **Settings can no longer be silently wiped (data-safety)** — `JSONFileStore`
  treated any unreadable file as "use empty defaults", and the first settings
  change then atomically OVERWROTE the file with those defaults — so one bad read
  of `settings.json` lost the instance URL, local tasks, colours, etc. (with no
  backup). Now every save mirrors the just-written good file to a `.bak`; `load`
  recovers the latest value from `.bak` if the main file is corrupt and preserves
  the bad file as `.corrupt` (nothing silently lost). Applies to all four stores
  (settings, learning, primed, pins). +2 checks. (The API key was never affected
  — it's a separate file.)
- [x] **Stop NEW OP duplicates at the real source: serialise sync** — duplicates
  were STILL appearing because `syncIfEnabled` had no re-entrancy guard, yet it's
  fired from ~7 places (every slice flush, the 60 s timer, every timeline edit).
  `pushEligible` fetches the unpushed sessions, then `await`s the network
  `createTimeEntry` before `markPushed` — and that await frees the main actor, so
  a second sync (e.g. the 60 s timer firing during a flush-triggered sync) fetched
  the SAME still-unpushed session and POSTed it again = two OP entries. The
  earlier rank-3a fix only covered a `markPushed` throw, not two runs that both
  succeed. `syncIfEnabled` is now non-reentrant (a `syncing` flag), with a
  `syncRequested` re-run so a trigger arriving mid-sync isn't lost. This is the
  root cause of the ongoing duplicate creation.

## 2026-06-27

- [x] **Reconcile robustness + display fixes** (from live testing) — three real
  problems with the duplicate tool:
  - **Safety:** grouping keyed on task+start-minute alone, so on an OP instance
    that doesn't report per-entry start times every entry collapsed to the day's
    midnight and genuinely-separate entries could be grouped as "duplicates".
    Grouping now also keys on duration, and — the real safety rail — the JOURNAL
    decides how many entries are real (slices linked to the group, or matching
    task+minute+duration); only the EXCESS over that count is ever deleted, so
    two real same-day slices are never collapsed. (+2 checks.)
  - **"created ?":** OP timestamps with fractional seconds were rejected by the
    default ISO-8601 parser; `parseStamp` now tolerates them.
  - **"start 0:00":** when OP reports no start time, the entry no longer shows a
    misleading midnight — it reads "no start time" and the group header omits the
    time, leaning on the created timestamp instead (`OPTimeEntry.hasStart`).
- [x] **OpenProject duplicate-entry reconcile (rank 3 complete)** — an in-app
  maintenance action (Settings ▸ Maintenance ▸ "Scan for duplicate OpenProject
  entries"). Reads back your recent OP time entries (`listTimeEntries`), groups
  them against the journal, and for each genuine duplicate proposes a confirm-
  each cleanup following the agreed policy: never two records for one point in
  time; keep the RICHEST entry (most comment, then longest, then lowest id); fold
  the deleted entries' comments into the survivor (`updateTimeEntryComment`, so
  nothing is lost); re-point the journal slices at the survivor; and never touch a
  group with no matching journal slice (could be hand-entered in OP). Pure
  `DuplicateReconcile` core (4 checks) + the OP endpoint (mock-transport check) +
  controller `findDuplicateActions`/`applyReconcile` + the confirm-each UI. This
  is the cleanup half; the double-create that *made* new dupes was closed earlier
  today (rank 3a). Each group expands (chevron, or Expand all) to show every
  entry's id, created time, duration, activity and comment so you can judge
  safety before deleting, with KEEP/delete tags; and an "open in OpenProject"
  per entry (opens its work package) to check anything Ambitick can't read —
  custom fields etc. (`listTimeEntries` now also reads createdAt/updatedAt/
  activity).
- [x] **Backlog batch (drafted by subagents, integrated + verified serially)** —
  five contained optimisation items, each built and checked on the Mac before
  the next; 160 checks pass.
  - **Rank 2 crash-safety:** a task switch now clears-then-rewrites the live
    checkpoint to the new task (a crash mid-switch could otherwise double-recover
    already-flushed time); new pure Core `CheckpointRecovery` rejects a stale row
    that's sub-floor or already covered; dedicated ~12s checkpoint timer gated to
    tracking (tolerance-coalesced). Plus `JournalStore.session(id:)` /
    `sessionCount()` / `pushedCount()` so edit/undo paths and the journal summary
    stop decoding the whole table.
  - **Rank 6 banked menu-clock:** under-counted during heavy flitting; now
    derived from `tracker.liveSliceStart` (= what posts to OP).
  - **Rank 3a OP double-create:** `SyncEngine` was marking pushed after the POST,
    so a failed mark re-POSTed next sync (the ~143-surplus root); the create is
    idempotent now (delete the orphan on a failed mark; surface a malformed id).
  - **Rank 7 test backfill:** SessionTracker live-editing/away, parser aliases,
    PinScope about:blank fallthrough (+9 checks, no hidden bugs surfaced).
  - **Rank 8 dead-code:** removed `WorkspaceLayout.swift` (228 dormant lines) and
    the dormant `taskLayouts`/`lastLayout` settings.
- [x] **Timeline: ⌘A selects all windows** in a slice once you've selected one
  (the span-reassign bar carries the shortcut).
- [x] **Faster Time window + readable "why" panel** — the pie window was slow
  because `SpentView.nodes` was a computed property running a journal query +
  TimeAggregator pass on EVERY body render, and the view re-renders ~1Hz (the
  menu clock), so it re-queried the journal about once a second. Now cached in
  `@State`, refreshed only on appear / the 30s tick / journal mutation / period /
  OP-only toggle. Also made the active-space window config idempotent (it re-ran
  per render). The attribution "why" panel was clipped with no scroll — each
  detail pane now scrolls vertically so the full explanation is reachable.
- [x] **One Time window, two views in place + a second-window escape hatch** —
  the timeline and pie are no longer separate windows that swap; they're one
  "Time" window whose view flips in place when you click a preview. To see both
  at once, ⌃-click / right-click (or the preview's context menu) opens the other
  view in a second window. App.swift now has `time` + `time2` windows hosting a
  `TimeContainer` bound to `controller.timeWindowView` / `timeWindow2View`;
  TimelineView/SpentView take a `TimeNav` (switchTo / openSecond) instead of
  opening/dismissing windows themselves; the window identity tracks the shown
  view so the scroll-pan monitor still recognises the timeline.
- [x] **User manual** — `MANUAL.md` (linked from the README): popover, auto-
  tracking + the "why" panel, pinning, the Time window incl. the combined-view
  navigation and the ⌃/right-click second window, Settings, data/sync, keyboard.
- [x] **Combined Timeline/Pie view — the previews ARE the navigation (#5)** — the
  popover's two separate Timeline/Pie footer icons are now one launcher that
  itself shows a **live mini-pie of today's breakdown**; clicking it opens the
  timeline, the pie, or whichever was viewed last, per a 3-way Setting (Time
  button opens: Timeline / Last viewed / Pie chart). There's no separate switcher
  icon: in the timeline window, clicking the today mini-pie opens the pie; in the
  pie window, clicking a slice in the current-block mini-timeline opens the full
  timeline **framed on and editing that exact slice** (via
  `AppController.pendingTimelineFocus`). The mini-timeline is labelled with the
  first slice's start time. Last-viewed persists across a relaunch. New
  `TimeViewChrome.swift` (`MiniPie` + tappable `MiniTimeline`); controller
  `todaySpentNodes`/`currentBlock`/`timeViewToOpen`/`noteTimeViewOpened`; all
  three surfaces cache the journal query rather than running it per render.
- [x] **Explainable attribution — "why was this tracked as X?" (#1 v1)** — click
  a slice, click a window in its detail strip, and the pane shows why that task
  was chosen: the decision source (pinned / OP-URL / OP-id-in-title / just-opened
  OP task / remembered correction / learned+priors), the ranked candidate tasks
  each with their score split into learned-vs-prior, and the signal features the
  learner keys on. `AttributionExplanation` + `Attributor.explain()` mirror
  `attribute()`'s source order so the explanation can't disagree with reality;
  `scored()` refactored to expose its components. Moving a window to the right
  task already teaches the learner, so that's the weight-edit loop — the panel
  points you to it and shows the scores. Controller `explainSpan`/`teachSurface`.
- [x] **Deep-review optimisation passes (ranks 1, 4, 5)** —
  - **Rank 1:** `liveStartConflicts` (warning) and `adjustLiveStart` (trim) now
    derive from one `liveEditContext(from:to:)` window, so the overlap warning
    equals what's actually trimmed even across midnight (they previously used
    independent calendar-day windows that could desync).
  - **Rank 4:** a slice deliberately started that ran 61–120s under a Switch
    Buffer set >60s was silently dropped at flush — floored at `min(buffer,60)`
    now (it's work, Martin's call; default 30s unchanged). `PinOp.startsWith` is
    case-insensitive like `equals`/`contains`. `matchingPin` only compares
    specificity within a rule kind (prefix.count vs leafCount aren't
    commensurable), else falls through to recency. `.regex` documented as
    unanchored. +3 regression checks.
  - **Rank 5:** the timeline scroll-pan monitor gates on the window identifier
    (set via `openOnActiveSpace(id:)`) not a localisable title substring, and is
    idempotent (no stacked global monitor → no app-wide double-pan).
- [x] **Renamed `KeychainStore` → `APIKeyStore`** — it has stored the OP API key
  in a plain 0600 file, not the Keychain, since 2026-06-24; the name was
  misleading.
- [x] **Popover tidy (#2/#3/#4)** — removed the pencil/double-arrow mode icons
  (the running-task title flips Change-to ⇄ Switch-to; the default is now a
  Setting, `popoverDefaultsToChangeMode`, defaulting to Change-to); dropped the
  separate unpin-✕ on the pin badge (the chip reopens the editor, whose ✕
  unpins); dropped the task name duplicated under the headline (popover shows
  `elapsedText`, time only).

## 2026-06-26

- [x] **Optimisation programme — passes 1–3** (Programme Manager + per-domain
  Project Managers analysed Ambitick; deep-review pending a credit reset). Done:
  - **perf:** added the missing `sessions(start)` index; `sessions(from:to:)`
    now bounds both sides in SQL via a new `end` column (was: decode every row
    before `to`, filter in Swift); hoisted per-push `ISO8601DateFormatter`;
    de-duplicated the triplicated dominant-span idiom into `dominantSpan(of:)`.
  - **fix (cross-midnight #8 follow-up):** `coalesceAdjacent`, `commitLiveSlice`
    and `lastTrackedTask` still bucketed by calendar day, so same-task slices
    straddling midnight didn't merge, a pre-midnight live slice wasn't found on
    commit, and the post-midnight resume candidate was empty. Now window-around-
    the-edit / live-slice-start / 36h-lookback respectively.
  - **perf:** `TimelineView` cached its journal fetch (`@State` + a
    `journalRevision` mutation signal) instead of running a SQLite query + JSON
    decode on every `sessions` access — it was re-querying inside gesture
    `.onChanged` closures and on every mouse-move.
  - Remaining backlog captured in TODO.md (gesture robustness, menu/banked-clock,
    attribution deep pass, crash-safety, OP write path, test extraction, dead
    code, backend seam).
- [x] **Removed the redundant "Recent/Likely tasks in popover" counts (#4)** —
  the popover now shows the whole task list (recency-first, then ranked,
  scrollable + filterable), so a fixed recent/likely cap was meaningless. Dropped
  both Settings, the `AmbitickSettings` fields, and `TaskRanker.pickList`'s
  count parameters; the ordering is now `TaskRanker.recentThenRanked` (recently-
  confirmed first, then everything ranked, no caps). Old settings JSON with the
  keys still decodes (the keys are just ignored).
- [x] **Pin parse errors are now legible** — the earlier tap-to-expand showed
  the error inside the cramped button row, overlapping the icons. The error now
  has its own full-width wrapping line above the buttons (selectable). `PopoverView`.
- [x] **Window-name pins survive title volatility (#2 follow-up)** — a Ghostty
  window pinned by name ("electroPioreactor" → AEP-design) tracked as the wrong
  task because `PinScope.matches()` was a strict POSITIONAL prefix match, and a
  terminal prepends its mode to the title ("nvim — electroPioreactor"), sliding
  the name out of position 1 so the pin silently stopped matching and a broader
  Ghostty attribution won. App pins now match on PRESENCE: the app must match
  and every pinned title segment must appear somewhere in the title (any order).
  URL pins keep positional prefix (host/path is stable). `PinScope`. (Two
  subagents investigated; one proposed "the pin-precedence comparator is
  inverted" — verified false, `max(by:)` with `<` correctly picks highest
  specificity, and the specificity test passes; the real cause was matching, not
  selection.)
- [x] **Pin badge shows the most distinctive clause (#11)** — an Expression
  pin's badge showed the FIRST clause; it now shows the leaf with the longest
  value (the bit that actually identifies the pin). `Predicate.shortLabel`.
- [x] **Expression negation: `is not` / `does not contain` (#11)** — the parser
  now accepts natural negations (`app is not "Ghostty"`, `url does not contain
  "github"`, `title doesn't match "…"`), so the user's example parses.
  `PredicateParser` (+ checks).
- [x] **Pin parse errors are viewable in full (#11)** — a long parse error was
  truncated to one line; tap it to expand (and it's in the hover tooltip too).
  `PopoverView`.
- [x] **Popover filter is focused on open** — the "type to search all N tasks"
  hint promised typing would work, but the filter field had no focus so nothing
  happened. It's now focused when the popover opens (and the hint only shows
  while the filter has focus). `PopoverView`.

## 2026-06-25

- [x] **Pin editor hamburger: Components + Expression (#11)** — the boolean
  engine existed but only the visual Components editor was wired up. The pin
  editor now has a hamburger (between Pin and Cancel) switching Components ↔ a
  typed Expression editor. New `PredicateParser` (Core, 7 checks) parses the
  agreed syntax — `app/title/url` · `is/contains/starts with/matches` ·
  `and/or/not/( )`, bare text = contains-any-field — into the same `Predicate`
  the engine evaluates, and renders it back (so re-opening an Expression pin
  shows editable text). Switching into Expression seeds the box from the current
  Components selection. Parse errors show inline and keep the editor open. AI
  paste-back mode is the remaining phase. `AppController.commitPin(rule:)`,
  `PopoverView`.
- [x] **Continuous cross-midnight timeline (#8)** — the viewport was hard-
  bucketed per calendar day (clamped midnight..midnight, `dayOffset` stepper),
  so a work block spanning midnight couldn't be seen whole and you couldn't pan
  across the boundary. The timeline is now one continuous absolute-time window
  that pans/zooms freely across midnight; the only bounds are a 90-day history
  floor and the live edge (now). Sessions fetch by visible range
  (`timelineSessions(from:to:)`, replacing the per-day variant); grid ticks
  anchor to local midnight and show the date + a darker line at each day
  boundary; the header shows the visible date (or a cross-midnight range), ‹ ›
  pan by a day, Today jumps to midnight..now, Block to the latest run.
  `TimelineView` + `AppController`.
- [x] **Sub-minute excursions no longer journal a "0:00" slice** — a ~31 s dip
  into another window (longer than the 30 s Switch Buffer, under a displayed
  minute) committed as its own slice and showed `0:00`. A WORK switch now only
  commits once held a full minute (`sliceFloor = max(switchGraceSeconds, 60)`);
  briefer excursions fold back into the surrounding task, exactly as a
  sub-grace flit already did. Display still follows instantly; only the journal
  commit waits. Non-work auto-stop and the flush floor keep the user-set buffer
  (so a genuinely-short first/last slice survives). `SessionTracker`.
- [x] **Recency survives a restart** — `lastConfirmedAt` lived only in the
  in-memory cache, so a heavily-tracked task silently dropped out of the recent
  pick-list after a relaunch (the "where did Client Work go the morning after?"
  symptom). Recency is now re-derived from the journal at startup and on every
  OP refresh, taking the later of journal and in-memory. `AppController`.
- [x] **App pins default to app + window, not app-only** — most people run
  several windows of one app on different tasks (e.g. named Ghostty windows), so
  the useful default scope is the window, not the whole app. Titleless apps
  still default to app-only. Widen with ←. `PinScope.defaultPrefixCount`.
- [x] **Popover task list is fully scrollable** — the default list was hard-
  bounded to the recent+likely picks, so a task outside them was unreachable
  without typing a filter. It now shows the full ranked set (recent+likely
  first), scrollable. With the recency fix above, the wanted task rises to the
  top. `PopoverView`.
- [x] **Timeline zoom homes on the cursor** — ± buttons and pinch keep the time
  under the pointer fixed instead of fixing the viewport centre. `TimelineView`.
- [x] **Overlap resolution: whole-windows vs exact time** — editing a slice end
  over a neighbour now offers two resolutions: Snap to windows (↵, default)
  moves the boundary to the nearest tracked-window edge so a straddling window
  lands wholly on one task (no duplicate-under-both-slices, no 1-min overlap);
  Exact time (space) keeps the time typed. `TimelineView` + `windowBoundaries`.
- [x] **Keyboard: delete/backspace removes selected slice(s)** — and a Delete
  button on the multi-select reassign bar. First step of the keyboard/mouse
  parity sweep (see TODO). `TimelineView`.
- [x] **Pin editor ✕ now unpins** (instead of a redundant exit-without-saving) —
  Enter is the only way to keep a pin; the ✕ (and esc) mean "no pin here", so
  they unpin an existing pin (same as the badge ✕) or drop a never-committed
  draft. `PopoverView`.
- [x] **Editor field focus no longer stolen mid-edit** — the 30 s refresh tick
  rebuilt the editor subtree and dropped focus from the h:mm field you'd just
  clicked (the intermittent "it didn't go blue" bug). The tick now pauses while
  the editor is open. `TimelineView`.

## 2026-06-24

- [x] **OP API key moved out of the Keychain to a 0600 file (stop the
  login-password prompt on every launch)** — a self-signed / no-Apple-team app
  cannot read its own login-keychain item without macOS challenging for the
  login password at every launch, and "Always Allow" never persists because the
  system won't trust an unanchored signature across rebuilds (the data-protection
  keychain that avoids the prompt needs an entitlement a teamless app can't
  get). `make-app.sh` now relaunches the app, so this fired on every build. The
  key now lives in an owner-only file in the app support folder beside the
  journal/settings (already plaintext there — same on-disk posture). Requires
  re-entering the OP API key once in Settings; the old keychain item is left
  orphaned and harmless. (`KeychainStore` kept as the type name for call-site
  stability; it is no longer a keychain.)
- [x] **Pins no longer instant-commit on every flit (the real flit-gap cause)** —
  debug-trace evidence: pinned windows attribute at score 1.0, which hit the
  `>= 0.96` "deliberate, commit at once" path and bypassed the grace window. So
  flitting THROUGH a pinned window (the user pins several Ghostty windows to
  different tasks) instant-committed a switch each time, fragmenting the base
  task into pieces with floored gaps between — and pushed 2-second slices to OP.
  That `>= 0.96` path existed for OP work-package URLs at 0.99, but those are now
  capped at 0.95, so nothing legitimate needs it. Removed it: every
  attribution-driven switch now respects the Switch Buffer (display still
  follows instantly; only the commit waits), so flitting through pinned windows
  folds back into the base task and the timeline stays continuous. Manual picks
  (confirm/start) are unaffected. KNOWN FOLLOW-UP: the menu-bar clock uses a
  separate per-task accumulator that still credits brief excursions to the
  excursion's task, so it can under-count during heavy flitting even though the
  journal/timeline is now correct — to be fixed next. (+ test; 122 total pass.)
- [x] **Flitting through a non-work tab no longer auto-stops the clock** — the
  pending-switch handler skipped `doNotTrack`, so a pending non-work stop was
  never cancelled when you returned to work: flit to a non-work tab, come back
  within grace, and ~30 s later the clock auto-stopped anyway. That "pause"
  couldn't be reclaimed because click-to-fill only fills *between* slices and a
  stop leaves open-ended trailing time. Now a pending non-work stop is cancelled
  the instant a real task is back in focus. (+ test; 122 total pass.)
- [x] **Hard floor on slice length, tied to the user's Switch Buffer** —
  emitted sessions had no minimum length (the `minSegmentSeconds` check only
  ever gated the review queue), so brief slices could still land (e.g. a pin
  instant-commit that bypasses the switch grace). `flushSessions` now drops any
  run shorter than `switchGraceSeconds` — the same "Switch buffer" knob in
  Settings, since it's the same idea (minimum time on a task for it to count),
  so it's user-settable with no new control. The grace fix stops most flits
  upstream; this floor guarantees the "pile of ~0-minute slices" can't appear
  regardless of path. NOTE: forward-looking only — slices journalled before this
  build stay until deleted in the timeline. (+ test; 121 total pass.)
- [x] **Settings/other windows open on the current Space** — opening a window
  (e.g. the gear) yanked you to whichever Desktop it was last on; they now use
  `.moveToActiveSpace` so the window comes to you instead.
- [x] **Settings text fields are visibly editable** — added rounded borders to
  the Instance URL / API key / colour fields (they were borderless and low
  contrast). Missing-API-key error now points at the Settings gear rather than
  a non-existent "below" field; "Saved to Keychain" → "Saved".
- [x] **Rapid window-flitting no longer logs a pile of sub-minute slices** —
  root cause in `SessionTracker.handleFocus`: when a switch A→B was pending
  (provisional through the grace window) and a third window C appeared, the code
  committed B regardless of how briefly it had been focused ("a newer task
  arrived, so B must have been real"). So flitting A→B→C→D committed each
  transient window as its own sub-minute slice, attributed to whatever the
  ranker guessed (the "a university course / Project B / Timesheets at 15:09" mess); and
  when one flit was an uncertain/doNotTrack window it auto-stopped, so the real
  work window that followed couldn't resume and logged as "nothing". Fix: a
  pending excursion that hasn't matured past grace is never committed — when a
  third task arrives it folds back into the base task and the new target pends
  from that same base. Only a window actually held past the grace window
  commits. `minSegmentSeconds` only ever gated the review queue, never sessions
  — the grace bug, not a missing floor, was producing the tiny slices. New
  SessionTracker check reproducing the flit (120 total pass).

- [x] **Pin rule engine (phase 1 of richer pins)** — generalised pins from a
  fixed component-prefix to a predicate so they can match windows that the
  URL/title-prefix model can't. A `Pin` now carries a `PinRule` that is either
  `.components(PinScope)` (the existing blue/grey editor) or `.expression(Predicate)`
  — a boolean tree of `field op value` leaves where field ∈ {app, title, url},
  op ∈ {equals, contains, startsWith, regex}, combined with AND/OR/NOT. This
  folds "contains" and "regex" into operators (no separate rule types — less
  code, the anti-bloat path), and is the shape the upcoming AI mode emits.
  Precedence when several pins match: manual `priority` (Advanced, hook present,
  UI TODO) → leaf-count specificity → most-recently-added. Attributor pins moved
  from a `[PinScope: TaskRef]` dict to an ordered `[Pin]`; legacy `pins.json`
  auto-migrates to `.components` rules on load. New `Predicate`/`PinRule`/`Pin`
  types + 5 Predicate checks + reworked Attributor checks (119 total pass).
  NOTE confirmed in design: the app sees only app name, window title, and (for
  browsers) tab URL — never window contents. Deferred to TODO: visual/webpage
  boolean builder, the typed-expression + Contains editors and hamburger
  mode-switch, AI mode (+ "fix this pin" follow-up), opt-in "look inside" apps
  (AX window-content as a 4th field), and the priority-override UI.
- [x] **Pin live-refresh** — committing a pin now re-evaluates the running
  session immediately (`SessionTracker.reevaluate()`), so the chip/100% appears
  at once instead of only on the next focus change.

## 2026-06-23

- [x] **Explicit pins + a clean certainty contract (the general fix for "it
  refuses to learn")** — root cause was architectural: attribution blended a
  naive-Bayes model with a volatile recency/status ranker prior, and surfaces
  with no durable anchor (My Page, dashboards) rode that prior to whatever
  project was hottest — the "apparently random project" Martin saw. Corrections
  to non-OP windows also drifted because a soft prime keys on the exact surface
  and for native windows that's `app + window title`, which churns (filename,
  cwd). New model, two tiers: **(1)** everything inferred — work-package URL,
  learned model, soft primes from ordinary corrections — now caps at **0.95**;
  **(2)** an explicit user **pin** is the only thing that returns **1.0**, and
  it overrides the ranker, learning, soft primes *and even a work-package URL*.
  A pin (`PinScope`) keys on a chosen **scope** — a broad→narrow prefix of the
  surface identity — so one pin covers a whole site, a section, a single page,
  a whole app, or one window. Most-specific (longest-prefix) pin wins. Pins
  persist to `pins.json`. The popover gets an inline **pin editor**: the
  captured identifier shows with the pinned prefix in blue and the rest grey,
  **← widens / → narrows** by `/`-level (URL) or title segment (app), the smart
  default is host+first-segment (URL) or app-only (native), **↵ pins / esc
  cancels**; a 📌 badge with ✕ shows/clears the active pin. The certainty number
  now means something honest: 100% ⟺ you told me outright, ≤95% ⟺ inferred.
  New `PinScope` type + 7 unit checks + 6 reworked Attributor checks
  (111 total pass). Supersedes the OP-only auto-pin from earlier the same day.
- [x] **Live-tracking & attribution fixes (Martin's in-app testing round)** —
  the live slice now renders as a continuation of its merged same-task block
  instead of a detached fragment; "Change to <task>" now *durably teaches* the
  attributor (it was a soft prime the learned model overrode, so windows
  snapped back to their old task on return); "revert" offers the task you
  actually just left (in-memory previous-task, not the journal's stray
  most-recent-by-start slice); the AI-assist parser skips unrecognised segment
  ids instead of rejecting the whole batch on the first bad one; the timeline
  viewport no longer drifts past the live edge into empty future time; and
  popover/settings text is selectable so it can be copied out instead of
  screenshotted. Workspace layouts cut (geometry-only, unreliable — see TODO).
- [x] **Stable code-signing fixed in `make-app.sh`** — it had been silently
  falling back to ad-hoc on every build, so the Accessibility/TCC grant was
  lost on each rebuild. Pinned cert creation to `/usr/bin/openssl` (Homebrew
  OpenSSL 3 writes a `.p12` that `security import` rejects) and dropped the
  `-v` filter from the identity lookup (it hides untrusted self-signed certs,
  which codesign signs with fine). Now prints `Signed with stable identity …`;
  grants persist across rebuilds.

## 2026-06-22

- [x] **Slices auto-merge; manual Stop→Start is the only discrete boundary** —
  `coalesceAdjacent` now runs at the flush sink (`onSession`) and after the
  idle-gap claim, so "continue when you were away", "revert to last task" and
  every other live-created slice fold into the adjacent same-task slice — one
  slice, one OP entry — instead of fragmenting. Adjacency uses the existing 2s
  tolerance, so a real untracked gap (a manual Stop then Start) stays two
  slices: the sole intentional break, e.g. for different comments.
- [x] **OP duplicate-on-merge fixed (was latent on the drag path too)** — a
  merged survivor kept the earlier slice's `opTimeEntryID` but was flagged for
  re-push, and `pushEligible` only ever *creates*, so each merge would spawn a
  second time entry. `coalesceAdjacent` now PATCHes the survivor's existing OP
  entry in place and marks it handled; auto-merge also skips the live
  crash-checkpoint row.
- [x] **Comment toggles: 'to tracked time' and 'to task'** — two independent
  settings (both default on). 'To tracked time' keeps the note on the time
  entry; 'to task' also posts it to the task's OP activity feed (new
  `OPClient.addWorkPackageComment`), where it is findable. Both off hides the
  note field. Routing is a pure, unit-checked `CommentRouting` helper. 98
  checks green; full SwiftUI build clean.

## 2026-06-12

- [x] **Timeline, Time Spent, local tasks (the `timeline` branch)** - Full
  interactive timeline (viewport bar, block-framing, draw/gap-fill/edge-drag
  editing with snapping and neighbour-trim, OP write-back via stored entry
  ids, window-detail strip with connectors, live-slice start edit), Time
  Spent donut (project>task>app hover rings, pin, legend), local non-OP task
  system with Settings UI and leisure routing, per-task colours, span
  recording with 30-day retention, crash traps to the debug log, self-drawn
  notification banners, per-task banked clocks with flash-visit limbo.
  81 checks + live-OP integration green throughout.

## 2026-06-11

- [x] **Ambitick v0.1 pre-alpha (overnight build)** — Full first implementation
  from the approved spec, e6a62dd..HEAD. `AmbitickCore`: domain models, OP URL
  parsing, naive-Bayes learning store, status/recency/time-of-day ranking,
  attribution with OP task-priming and OP-host fallback, dominant-minute
  session resolution, journal protocol, OpenProject v3 client (1-based page
  pagination), threshold-gated sync, copy-paste AI assist, settings.
  `AmbitickMac`: raw-sqlite3 journal (passes the same conformance suite),
  Keychain key storage, sensors (frontmost app, AX window titles, Chrome/Opera/
  Brave tab URLs via Apple Events, idle, sleep/wake, mic-in-use), app
  controller with 1 Hz→per-minute menu cadence. `AmbitickApp`: SwiftUI
  MenuBarExtra popover, review window (multi-select assign), settings UI.
  `scripts/make-app.sh` wraps it as ad-hoc-signed `Ambitick.app` (LSUIElement).
  56 checks green via `swift run AmbitickCoreChecks` — a plain-executable
  harness because the build Mac has CLT only (no XCTest/Swift Testing).
  Verified on Mac over scoped SSH (`ambitick` standard user). UI smoke testing
  deliberately deferred to Martin (README checklist): no GUI session available
  to the build user.

## 2026-06-11 (day-2 fixes)

- [x] **Live-fire fixes + real-OP integration runner** — switch-grace buffer
  (brief window excursions merge; commits via input ticks), per-task clock,
  s/m/h+m menu format, persistent primed associations, weighted session
  certainty, optional activity, ISO-8601 startTime (verified stored by OP),
  stable signing identity (TCC grants survive rebuilds), legacy notification
  API (process-abort fix), auto-resume after idle, loud connection/push
  diagnostics, popover/review type-to-filter, AmbitickIntegration headless
  end-to-end against live OP as the Claude test account. 69 unit checks +
  INTEGRATION PASS.

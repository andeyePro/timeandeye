# TODO

## Review drawer (Martin's critique, 2026-07-10)

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
- [ ] Adjacency boost beyond the drawer: `AdjacencyBoost` (2026-07-10) is
  deliberately DISPLAY/ORDERING only — journalled certainty, the retro
  pass and auto-push never see it. Feeding it into posting semantics would
  change what auto-pushes without review, so it needs its own decision (and
  probably the constant-fitting pass first: every applied boost is already
  DebugLog'd so the 60%/30%/decay constants can be fitted from correction
  outcomes).

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
- [ ] Live pick (`userPicked`) and Stop are live-tracking controls, not data
  edits — ⌘Z doesn't touch them by design (compensators: the popover's ←
  revert, and the timeline edits every flushed slice). Confirm that stance
  or fold picks into the stack.
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

- [ ] Sensor poll runs the Chrome-tab AppleScript + AX title read synchronously
  on the main actor every 2 s (Sensors.swift poll). Same hazard class as the
  2026-06-30 email-capture freeze, just lower probability (a hung/modal Chrome
  stalls tracking AND the UI). Fix = move poll() off the main run loop or fetch
  URL/title on a background queue and feed results back as events. Needs
  on-device soak — the email capture revert proves this path bites.
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

- [ ] Journal the decision SOURCE alongside task+certainty. The why-panel
  truth fix (2026-07-10) anchors the timeline card's BECAUSE on the slice's
  recorded outcome, but the journal keeps only WHAT stood (task, certainty),
  not WHICH source decided it (pin / sticky / rule / prime / ranked) — so
  the card can say "this time stands as → X" but not name the original
  firing source, and demotes today's re-derivation to "would say" instead.
  Recording `AttributionExplanation.Source` (+ matched rule/key) on
  Session/FocusSpan at flush would let BECAUSE tell the original story
  verbatim. Codable back-compat via decodeIfPresent; decide whether
  reassigns overwrite or append to the provenance.

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
  4 render-contract checks; suite 669/0. Mon pin: branch FableMax until
  main; 
- [ ] Invoice NUMBER for the invoice-lock ref needs the Xero Accounting API
  (Projects API doesn't expose it — verified 2026-07-08); until then locks
  group under the single ref "Xero".

- [ ] Relocate the AndeyeLogo geometry out of timeandeyeCore into
  timeandeyeTheme (or a leaf brand target): sibling andeye apps that only
  want the mark currently drag the whole engine in for it. Consumers to
  repoint: AndeyeMark (timeandeyeTheme), AndeyeLogoImage +
  AppController (timeandeyeMac), RootScenes (timeandeyeUI), the
  AndeyeLogoChecks/ThemeChecks suites, and the site's literal-port
  reference comments (site/src/pages/index.astro,
  site/src/components/AndeyeSiteTitle.astro). Waits for a quiet window —
  it's cross-product churn (Mon consumes the theme product too).

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
- [x] Pin editor AI mode (#11, DONE 2026-06-28). Fourth hamburger entry "AI":
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
- [ ] Ambiguous web pages (no clear purpose in URL/title) — POLICY (proposed
  2026-07-01, awaiting Martin's steer sticky-vs-review). Treat the URL HOST as a
  first-class domain signal, the web sibling of the email correspondent-domain
  ladder: one correction generalises the whole host (github.com → task). When
  nothing matches (no pin/OP/learned host): be STICKY — keep the current task and
  read low-certainty (red), rather than yanking onto the top ranked guess; a
  sustained unknown page surfaces a one-tap "this site → task" (which learns the
  host). Truly transient pages (new tab, a search) keep the prior task / a
  don't-switch host list. Fold "web host" in as another ladder level later.
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
  menu-bar flash (ships OFF pending Martin's), review-stack hint chips
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

- [x] Build the multi-backend seam + billable flag per .vs/spec.md
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

- [x] [+all] button — DONE 2026-07-08 overnight (Martin's 01:53 the maintainer channel
  request): "+ all" appears top-right of the detail strip whenever the
  current selection has unselected twins (identity = app + title + tab URL,
  never the times); one click extends the selection to all of them; help
  text counts what it will add. Full build + suite green on the bridge.
- [ ] [+similar] button (later, non-critical) — pressable repeatedly to
  accumulate windows similar to the current one; a paired [-similar] steps
  the accumulation back so you can undo over-pressing. After [+all].

 — from Pro coordination (2026-07-07, website side owns)





































## Comment-loss edge (2026-07-07, pre-existing, low priority)

- [ ] A committed comment (in manualNote) on a slice that is then DROPPED as
  a sub-grace flit and immediately followed by a stop is lost at
  AppController onState (:598 clears the un-banked note). Rare; pre-existing
  (predates the enter-to-commit rework). Fix would bank a pending note onto
  the nearest kept slice, or hold it for the next slice, before the stop
  clear. Flagged by the reassign/comment review.

## Timeline/menu-bar issues from hardware test (2026-07-07, Opus, post-Fable)

- [ ] Elapsed desync: menu bar and timeline agree on the TASK now but not
  the ELAPSED — Martin saw menu bar "2s and counting" vs timeline "8 min"
  for the same task (a client project). Likely cause: a per-window
  reassign (commitLiveSlice) banks the live run and resets targetSince to
  now, so the menu clock restarts while the timeline live slice still spans
  liveSliceStart (whole block). Decide the intended semantics (menu shows
  whole-block total? or the timeline reflects the bank?) and make them
  consistent. Opus job.
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
- [x] RUN `swift run andeyeTTChecks` on the Mac — DONE 2026-07-08 00:2x BST
  via the the local build bridge bridge: TOTAL 441 passed, 0 failed (twice).
  Needed `rm -rf .build` on the Mac tree (stale module cache) and one
  pre-existing flaky check deflaked (ContextRules surface bytes).
- [ ] Martin: LOCK the licence spec §1 (open Qs 1–5 now carry Fable
  recommendations; F1 floor correction applied — standard connectors `.plus`).
  Then commit the v2 build; do NOT sell any plus SKU before the entitlement
  gate ships end-to-end (spec's own launch-blocker rule).
- [ ] FableReview.md: triage the 23 findings — F8 (resolveOverlaps unwired),
  F9/F10 (multi-device posting ledger), F11 (edits never amend finance),
  F23 (middle-split destroys the smaller side) are the pre-CloudKit-GA set;
  full designs in docs/superpowers/specs/2026-07-07-multidevice-posting-
  correctness.md (D0–D7 + 14 acceptance criteria).
- [x] Wire Settings surfacing — DONE 2026-07-08 (overnight): Posting health
  section (stuck + Retry, diverged counts); permanentlySkipped surfaces via
  lastError. REMAINING: entitlement-denial copy — lands with the cross-repo
  `requires:` seam change (gate is dormant until then).
- [ ] Pro repo: thread `XeroConnector.entitlement` through the seam once
  `register(..., requires:)` exists on BackendRegistrar (coordinated
  cross-repo change; main side already has the gated registry method).

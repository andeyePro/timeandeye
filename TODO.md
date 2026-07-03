# TODO

## Time-window polish (Martin, 2026-06-27)

- [x] Window titles (DONE 2026-06-28): the Time window is titled "Timeline" when showing the
  timeline and "Time Pie" when showing the pie (currently "Ambitick Time").
- [x] Pie view — closeable highlight-calendar (DONE 2026-06-28). Anchorable
  `TimePeriod` in Core (unit-checked); a `MonthCalendar` grid bottom-right (below
  the key) highlights the shown range and re-anchors on a tapped day; the period
  picker moved below the calendar. "This week" → tapped day's whole week;
  "Last 7 days" → 7 days ending on today's weekday; future days disabled.
- [x] Pie view — OpenProject-only + total moved bottom-left (DONE 2026-06-28).
- [ ] Reconcile "open in OpenProject" currently opens the entry's work package
  (OP has no per-time-entry web page). Find a better deep-link to the WP's time
  entries / cost view if one is stable across OP versions.

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
  data to chase the live mis-attribution bugs (tracking as Ambitick while on
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
- [ ] `fullPickList()`/`searchTasks()` (full ranker sort + fuzzy filter) are
  called inside SwiftUI `body` at several sites (PopoverView switchList,
  Timeline reassign/editor pickers, Spent reassign row, Review assign bar) —
  re-ran per render. The 1 Hz republish fix removes the worst trigger; the
  remaining cost is per-genuine-render. Proper fix: cache the ranked list in
  @State keyed on journalRevision/taskCache/filter, or one shared TaskPickerBar
  component (also collapses 4 near-duplicate filter-bar implementations).
- [ ] Two open timeline windows cross-pan: the app-global scroll monitor gates
  on `keyWindow?.identifier == "timeline"`, which both windows share. Gate on
  the window instance captured at install instead. (Known TODO, now with root
  cause.)
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
  note, 6907245). Multi-agent programme; start AFTER the andeyeTT folder
  rename/vibe reopen.
  Progress: diagnosis written 2026-07-03 (a90fe90, RC1/RC2/RC3 root-caused).
  (a) DONE 2026-07-03 — capture layer: `EmailCaptureEngine` (async,
  deadline-bounded `osascript` subprocess, one in flight) + `SessionTracker.
  applyEnrichment` (retroactive, same-surface-gated). Needs on-device soak
  before trust (the 6-30 lesson: checks alone didn't catch the freeze).
  (b)/(c)/(d) Core layer (ContextIdentity, EmailRule provenance, Attributor.
  forget/explainWithout) landed WIP 2e6f784 — UNVERIFIED, suite not run;
  Evidence Card UI (the context-rules-ux spec, 2026-07-03) not started.
  (e) not started.

- [x] BEFORE the FOSS publish: contributor IP mechanism. (DONE 2026-07-02 —
  Martin chose AGPL-3.0 + CLA; LICENSE, CLA.md and the CONTRIBUTING licence
  section landed in one commit. Still on the publish click-list (WP 223):
  Martin reviews the CLA text, and the enforcement check (CLA-assistant or
  PR-template line) is wired before the repo flips public.)
- [x] Generalise duplicate-reconcile beyond OP (2026-07-02, from the
  TaskRef.remote migration). (DONE 2026-07-02, 11c6d0a — RemoteTimeEntry is
  a real Core struct with String ids; ReconcileAction backend-neutral;
  OPBackend converts at its edge.)

- [ ] iCloud quota stewardship (Martin, 2026-07-02). Reality check first: the
  synced journal is TINY — a slice is a few hundred bytes, heavy tracking is
  ~50k slices/year ≈ 15–25 MB/year in the user's CloudKit private DB, and the
  bulky window-span detail is local-only (already 30-day pruned) and never
  syncs. Nobody gets pushed into a paid iCloud tier by Ambitick; photos do
  that. Still, build the stewardship story so the complaint can never land:
  (a) Settings shows Ambitick's actual iCloud footprint; (b) an
  age-consolidation prune — slices older than N years collapse into per-day
  per-task rollups (durations summed, comments concatenated, backend entry
  ids dropped) so totals/invoicing history survive at ~1% of the size;
  (c) an extreme hard-cap prune (delete oldest raw slices beyond a chosen MB
  ceiling), UI-labelled as strongly discouraged with a double confirm;
  (d) tombstone GC after 90 days (already in the sync design).

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
  URL, the page builds the expression, and returns it via an `ambitick://`
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
- [ ] Email auto-learner — Core engine SHIPPED 2026-06-30; Mac capture SHIPPED
  2026-06-30, REVERTED SAME DAY (5439a83 — synchronous `NSAppleScript` on the
  poll thread froze tracking), RE-ENABLED 2026-07-03 (async/deadline-bounded/
  one-in-flight via `EmailCaptureEngine`, retired `NSAppleScript` for an
  `osascript` subprocess entirely — see the capture-layer entry below). Needs
  on-device soak before trust (checks alone didn't catch the 6-30 freeze).
  Correcting an email's task learns an EmailRule (org domain → company, shared
  webmail → person); matching mail auto-attributes via the `.emailRule` source
  through the user's ladder. Settings UI to reorder the ladder SHIPPED
  2026-07-01 (chevrons in "Email → task matching"). Explicit pin via
  `from`/`sender`/`subject` + `any` fields in the expression grammar SHIPPED
  2026-07-01 (PinField multi-valued; bare text now spans correspondents+subject).
  REMAINING for the full feature: more provider selectors
  (OWA/Proton/Yahoo/Fastmail) + native clients; validate-on-use / self-heal +
  recipe pack with background updates; multi-message-thread sender choice;
  derive own-domains from settings (beyond the "me" heuristic).
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
  diagnostics probe shares it too). REMAINING to make it a real signal: pick
  which message's sender in a multi-message thread; derive own-domains from
  settings/accounts; validate-on-use + recipe store/pack; other providers'
  selectors (OWA/Proton/Yahoo/Fastmail) + native clients.
- [ ] Pin rules — AI "fix this pin": from a pin that should have matched a
  window but didn't, regenerate the AI prompt including the failing rule + that
  window's fields + a free-text complaint, so the model corrects it. Iterative
  refine on top of the one-shot AI pin flow. - 2026-06-24
- [x] Backend seam + standalone mode (protocol half DONE 2026-07-01, see Rank 9
  above): `TaskBackend` extracted, OP behind it in-process, standalone = nil
  backend, activity picker hidden when the backend has none. Still open from
  this item: CSV/Markdown timesheet export (next), standalone comment storage.
  Plugin loader deferred until a second backend exists. - 2026-06-22
- [ ] Right-click 'Open in <backend>' (task URL from the connector); standalone
  → 'Open task' showing the timestamped comment list. - 2026-06-22
- [ ] Standalone 'comment to task' storage: persist notes against the local
  task in SQLite as a timestamped list (the standalone half of the comment
  toggles already shipped for OP). - 2026-06-22
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
  thin SwiftUI shell over AmbitickCore, and pre-1.0 Core API churns weekly — a
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
  closed-source, they move to a private `ambitick-pro` package the release
  builds depend on — the TaskBackend seam makes that a clean lift.




















- [ ] Safari, then Opera tab URLs; Chrome-PWA AppleScript support
- [ ] In-app onboarding flow (user 2)
- [ ] OP project-slug matching for the in-OP-without-task-id rule
- [ ] iPhone-side call detection
- [ ] Auto-comment as debugging aid is OFF by default now; revisit whether
  window summaries have any user value (Martin: prefers manual note only)
- [x] Attribution auto-prime (DONE 2026-06-28): a newly-created local task wasn't auto-associated
  with its window, so its time files under the previous task until the user
  reassigns once (reassign now teaches the association, so it self-corrects
  after the first fix). Consider auto-priming a local task to the frontmost
  window at creation time.
- [x] True global hotkey for "I'm leaving my desk" (DONE 2026-06-28) (currently ⌘⇧L works when
  Ambitick/its popover is key; a global RegisterEventHotKey would fire from
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

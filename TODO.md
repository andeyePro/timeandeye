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
- [ ] Rank 9 — backend seam (`TaskBackend`/`TimeSink`) + standalone mode, NEW
  branch: pure-Core slices first (TimesheetExport, task_comments table), then a
  behaviour-preserving protocol refactor (NullBackend must NOT silently become a
  no-op sink on misconfig; keep the typed-422 fallback), Attributor hook last.
  Absorbs the standalone TODO sub-items (local comment storage, open-in-backend,
  project-slug). Plugin loader stays deferred.

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

## Open

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
- [ ] Email auto-learner — Core engine + Mac capture SHIPPED 2026-06-30 (needs
  on-device validation). Correcting an email's task learns an EmailRule (org
  domain → company, shared webmail → person); matching mail auto-attributes via
  the `.emailRule` source through the user's ladder. Settings UI to reorder the
  ladder SHIPPED 2026-07-01 (chevrons in "Email → task matching"). Explicit pin
  via `from`/`sender`/`subject` + `any` fields in the expression grammar SHIPPED
  2026-07-01 (PinField multi-valued; bare text now spans correspondents+subject).
  REMAINING for the full feature: more provider selectors
  (OWA/Proton/Yahoo/Fastmail) + native clients; validate-on-use / self-heal +
  recipe pack with background updates; multi-message-thread sender choice;
  derive own-domains from settings (beyond the "me" heuristic).
- [ ] (b, 2026-06-29) Gmail sender extraction — CHANNEL + RECIPE FOUND.
  Chrome's renderer AX tree stays off (AXManualAccessibility didn't wake it), so
  the channel is page JavaScript over Apple Events (needs Chrome ▸ View ▸
  Developer ▸ Allow JavaScript from Apple Events). Validated Gmail recipe:
  `.gD` = open-message sender, `.g2` = recipients (a blanket `[email]`/
  `[data-hovercard-id]` query is polluted by the ~100+ inbox-list `.yP` rows Gmail
  keeps in the DOM). Gmail names your own address "me", so counterparties fall out
  cleanly. Foundation shipped: `EmailSystem` (detect + per-system selectors),
  `EmailSignal.Party`/`counterparties`/`domain` (pure, tested),
  `EmailSignalProbe.frontBrowserParties` (recipe-driven), surfaced in the
  Diagnostics probe. REMAINING to make it a real signal: thread sender/
  counterparty into the ActivitySignal + learner feature + pin `from` field; pick
  which message's sender in a multi-message thread; derive own-domains from
  settings/accounts; validate-on-use + recipe store/pack; other providers'
  selectors (OWA/Proton/Yahoo/Fastmail) + native clients.
- [ ] Pin rules — AI "fix this pin": from a pin that should have matched a
  window but didn't, regenerate the AI prompt including the failing rule + that
  window's fields + a free-text complaint, so the model corrects it. Iterative
  refine on top of the one-shot AI pin flow. - 2026-06-24
- [ ] Backend seam + standalone mode: extract a `TaskBackend`/`TimeSink`
  protocol, move OpenProject behind it in-process, and make "no backend" the
  null implementation so Ambitick runs standalone — local task list with CRUD,
  no-op sync, hidden activity types, CSV/Markdown timesheet export. Plugin
  loader deferred until a second backend exists. New branch. - 2026-06-22
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
- [ ] iOS companion app (manual 2-tap tracking; Core is ready)
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
- [ ] Martin to verify: timeline edits write back correctly to OpenProject and
  no data (windows etc.) is lost across edit/merge/split/reassign.

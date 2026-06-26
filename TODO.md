# TODO

## Optimisation backlog (programme review 2026-06-26)

A Programme-Manager + per-domain Project-Manager pass produced this. Three
passes already DONE (see CHANGELOG 2026-06-26): sessions index + bounded query,
cross-midnight controller fixes, TimelineView sessions cache. The deep-review
consolidation and two PMs (backend-seam, crash-safety) didn't run (session
credit limit) — resume the `ambitick-optimise` workflow after reset for the full
consolidated plan. Remaining items, by domain:

- [ ] Perf: `updateJournalSummary` decodes the WHOLE sessions table on every
  mutation — add COUNT-based queries (`sessionCount`/`pushedCount` on the
  JournalStore protocol) instead of `allSessions()`. Also: `applyTimelineEdit`/
  create/delete call `allSessions()` just to find one row — add `session(id:)`.
- [ ] Reliability: timeline gesture composition (draw vs gap-tap vs pinch vs
  per-slice tap vs edge-handle drag) — audit SwiftUI precedence; the scroll-pan
  NSEvent monitor gates on `keyWindow.title.contains("Timeline")` (brittle,
  localisation-fragile) — key off window identifier instead; confirm the global
  monitor can't leak/double-install.
- [ ] Perf/correctness: menu cadence + banked-clock — the 1Hz titleTimer runs
  forever though MenuTitle only needs sub-minute refresh in the first minute;
  and the banked-clock under-counts during heavy flitting (CHANGELOG 2026-06-24
  follow-up) — mirror the now-correct journal grace logic.
- [ ] Correctness (Core): attribution deep pass — confirm the grace floor +
  sliceFloor compose so a genuinely-short first/last slice survives; verify
  duration-weighted certainty; pin specificity compares `prefix.count` vs
  `Predicate.leafCount` across rule kinds (not obviously commensurable); regex
  PinOp compiles NSRegularExpression per `test()` call, unanchored — cache it.
- [ ] Reliability: crash-safe checkpoint + SQLite serialization audit — 60s
  checkpoint loses up to ~60s on a hard crash (also checkpoint on task switch?);
  verify every db access goes through the lock; signal-handler DebugLog.write is
  not async-signal-safe.
- [ ] OP write path: prove no path double-creates a time entry; failed-PATCH-
  during-coalesce leaves OP stale (retry/reconcile); build the journal-driven
  duplicate-entry cleanup (exact start+duration match, in-app maintenance).
- [ ] Test coverage: extract the cross-midnight day-window selection + coalesce
  logic out of AppController into Core/TimelineMath so it's unit-testable (it's
  controller-only glue today); add the missing SessionTracker grace edge cases.
- [ ] Dead code: WorkspaceLayout.swift (228 lines, dormant since the 2026-06-23
  cut) — delete and recover from git when re-added, or mark clearly; gate the
  per-launch legacy pins.json migration.
- [ ] Architecture (large, design-only so far): backend seam
  (`TaskBackend`/`TimeSink`) + standalone mode — see the dedicated item below.

## Open

- [ ] Full keyboard/mouse parity sweep (retrospective) — every action reachable
  by BOTH mouse-only and keyboard-only. Done so far: delete/backspace removes
  selected timeline slice(s). Still mouse-only: slice selection/navigation
  (arrow keys to move between slices, ⇧-arrow to extend), opening the editor,
  task picker navigation, span-strip selection, pin editor open, day navigation.
  STANDING RULE going forward: every new command ships with a keyboard path, not
  just a button.
- [ ] Pin editor AI mode (#11, remaining phase) — a fourth hamburger entry that
  builds an AI prompt from the captured fields (app/title/url) + an editable
  advice box (pre-seeded with the "prefer a stable title/URL pattern; if the
  title looks volatile, suggest a more robust field or a setup change" nudge),
  shows it scrollable, auto-copies it, and takes a paste-back that deserialises
  into a normal editable Components/Expression rule (or shows an error). Builds
  on the now-final rule format; the hamburger + Components + Expression shipped.
  Also: offer "couldn't parse this — generate an AI prompt from it?" on a
  parse-error tap, handing the failed expression to the AI mode as a starting
  point.
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
- [ ] Pin rules — priority override (Advanced settings): default precedence is
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
- [ ] OpenProject duplicate-entry cleanup: journal-driven reconcile, exact
  start+duration match only (never collapse genuinely-separate same-duration
  slices), as an in-app maintenance action — the MCP can see neither start
  times nor a delete verb. ~96 candidate groups / 143 surplus entries in the
  most-recent 500. - 2026-06-22
- [ ] Semantic task search in filters (find "voting" Ghostty's task without
  knowing its OP subject; substring filter is not enough) - Martin 2026-06-12
- [ ] Named local-only leisure/non-OP tasks (e.g. "Chess") creatable from the
  review window, instead of the single anonymous leisure bucket
- [ ] Keychain "Always Allow" still prompts once per new binary despite the
  stable signing identity - investigate ACL/designated-requirement pairing
- [ ] iOS companion app (manual 2-tap tracking; Core is ready)
- [ ] Safari, then Opera tab URLs; Chrome-PWA AppleScript support
- [ ] In-app onboarding flow (user 2)
- [ ] OP project-slug matching for the in-OP-without-task-id rule
- [ ] iPhone-side call detection
- [ ] Auto-comment as debugging aid is OFF by default now; revisit whether
  window summaries have any user value (Martin: prefers manual note only)
- [ ] Attribution: a newly-created local task (e.g. Games) isn't auto-associated
  with its window, so its time files under the previous task until the user
  reassigns once (reassign now teaches the association, so it self-corrects
  after the first fix). Consider auto-priming a local task to the frontmost
  window at creation time.
- [ ] Keyboard-only / mouse-only completeness audit: Enter saves + Esc cancels
  are wired in the timeline editor; do a full pass so EVERY action has both a
  keyboard and a mouse route (tab order, list arrow-key nav, popover focus).
- [ ] True global hotkey for "I'm leaving my desk" (currently ⌘⇧L works when
  Ambitick/its popover is key; a global RegisterEventHotKey would fire from
  any app).
- [ ] Martin to verify: timeline edits write back correctly to OpenProject and
  no data (windows etc.) is lost across edit/merge/split/reassign.

# TODO

## Open

- [ ] Timeline free-pan across days: drop the single-day viewport clamp so a
  block spanning midnight renders whole and the view scrolls continuously
  across day boundaries (storage already spans midnight — it is the
  `startOfDay`/`+86 400s` clamp in `TimelineView`). Geometry behind unit
  tests; Martin render-checks. - 2026-06-22
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
- [ ] Timeline phase 2: draw-to-create slices (drag + snapping), edge-drag
  handles that eat into neighbours, gap-click creates a gap-filling slice,
  connected zoom strip (lines from slice edges to detail strip), user-editable
  task colours, edit start time of the CURRENTLY tracked session
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

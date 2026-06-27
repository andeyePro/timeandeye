# TODO

## Optimisation backlog (programme review, consolidated 2026-06-26/27)

A Programme-Manager + per-domain Project-Manager pass, then an adversarial
deep-review, produced a 9-pass plan (CHANGELOG 2026-06-26/27 for what's landed).
DONE so far: store index + bounded query, TimelineView sessions cache,
cross-midnight controller fixes incl. the live-start pair (rank 1), attribution
floor/startsWith/tiebreak (rank 4), scroll-monitor hardening (rank 5),
formatter/dominant-span dedupe, KeychainStore→APIKeyStore. Remaining ranks:

- [ ] Rank 2 — crash-safety: a task switch never clears/rewrites the 60s
  checkpoint, so a hard crash can double-recover time already journalled
  (duplicate time + duplicate OP entry). Clear-then-rewrite the checkpoint on
  switch; extract a Core `CheckpointRecovery` (reject promotion when the stale
  span is already covered); tighten the checkpoint timer to ~12s while tracking
  (Martin: OK if no perf/energy hit — use a generous Timer tolerance so the OS
  coalesces the wakeup). Attach the superseded-survivors here: `session(id:)`
  single-row fetch + COUNT-based `updateJournalSummary` (stop decoding the whole
  table on every mutation).
- [ ] Rank 3 — OP write path: `SyncEngine` marks pushed AFTER the POST, so a
  throw after a successful create re-POSTs next sync (likely root of the ~143
  surplus entries). Make create idempotent across a failed mark (delete the
  orphan on the failure path); surface a malformed created-entry id instead of
  swallowing it. Then the journal-driven duplicate reconcile — DECIDED policy
  (Martin): never two records for one point in time; keep the RICHEST record
  (most likely the real one), fold the deleted record's data into the survivor
  as a comment (nothing irrecoverable), re-point the journal's opTimeEntryID to
  the survivor, confirm-EACH (no bulk auto-delete), never delete an OP entry
  with no exact journal match. Land before the backend seam.
- [ ] Rank 6 — banked menu-clock under-count: brief excursions re-tagged back to
  the base task aren't recovered by `bankedElapsed + running`; compute the
  tracking clock from `tracker.liveSliceStart` so it equals what posts to OP
  (CHANGELOG 2026-06-24 follow-up). Optional: gate the 1Hz title rebuild to
  first-minute/minute-boundary (keep the 1Hz timer for scheduledStop).
- [ ] Rank 7 — test backfill (pure test code): SessionTracker live-editing
  (commitLive/relabel/backdate/adjustCurrentStart/reevaluate/liveSliceStart) +
  away-mode; parser aliases/negations; PinScope malformed-URL fallthrough.
- [ ] Rank 8 — dead code: delete `WorkspaceLayout.swift` (228 dormant lines,
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

- [ ] #1 follow-on — beyond the shipped explain panel + move-to-teach loop: a
  direct learned-weight control (slider) on the why panel, and use the explain
  data to chase the live mis-attribution bugs (tracking as Ambitick while on
  Chrome; the revert button offering a stale task — `revertTargetTask` returns
  `previousTask`, which can be wrong; now diagnosable via the explain panel).
- [x] #5 — combined Timeline/Pie view: DONE (CHANGELOG 2026-06-27). Combined
  footer icon (opens timeline / pie / last-viewed per the 3-way Setting),
  in-window top-right switcher, cross-previews (today's mini-pie + total in the
  timeline; the current block's mini-timeline in the pie), last-viewed persists.
  Possible polish: richer mini-pie (task rings), make the cross-previews
  clickable to jump to that view.

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

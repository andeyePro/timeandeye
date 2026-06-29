# Changelog

## 2026-06-29

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

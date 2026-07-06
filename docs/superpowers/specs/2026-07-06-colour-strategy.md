# Colour strategy – design

Status: DESIGN (no code in this commit). Spec date 2026-07-06. Seeds a /vs
run once Martin has answered the open questions.

andeye colours every project, task and window surface so the pie and the
timeline read at a glance. Today the colour is a per-task hash with a
settings-dict override; there is no project-level colour, no inheritance,
no editing outside the timeline slice editor, and the pie's project ring
borrows the colour of whichever task happens to sort first. This spec
replaces that with a stable, user-ownable colour system: maximally distinct
hues between projects, tasks shaded within their project's spectrum,
click-any-swatch editing, an inherit/fixed choice down the hierarchy, and a
"Life" period so the whole estate can be coloured from one screen. The
governing principle throughout is COLOUR STABILITY – people build
colour-to-project associations, so a colour, once seen, never changes
underneath the user.

## 0. Open questions for Martin (answer before /vs build starts)

1. **Legend gesture split** – clicking a legend row currently expands/pins
   the project (SpentView.swift:606). Proposal: the SWATCH becomes the
   colour editor, the rest of the row keeps expand/pin. Confirm the split,
   or ask for a modifier (e.g. right-click swatch) instead.
2. **Explicit re-spread stays out of v1** – colours are never reassigned
   automatically (the stability principle). A user-triggered "re-spread
   colours" action (per-scope, undoable) could exist for someone who wants
   a fresh deal; recommend deferring it – stability makes it rarely
   needed and it is the one feature that can destroy every learned
   association in a click. Confirm defer.
3. **Migration seen-heuristic** – at first launch of the new store, every
   task with ANY journal time gets its current hash colour snapshotted as
   its permanent assignment ("has time" ≈ "has been seen in the pie"), and
   existing `taskColours` overrides migrate as user-fixed records. Tasks
   never tracked go through the new allocator on first sight. OK, or
   snapshot the whole pick-list cache too?
4. **Untracked filter source** – "Untracked" lists tasks andeye knows
   (backend task cache + local task definitions) that have zero journal
   time. Closed/deleted remote tasks that were never tracked will not
   appear. Confirm that is acceptable.
5. **Window-swatch identity grain** – editing a window's colour needs a
   stable surface key. Proposal: reuse the pin identity machinery
   (PinScope.identity – the same broad→narrow segments the pin editor
   shows), defaulting to the same smart prefix, so "this window's colour"
   generalises exactly like "this window's pin". Confirm, or restrict v1
   window colouring to whole-app grain.
6. **Colour-blind handling is always-on** – the distance metric that picks
   new hues always includes protan/deutan/tritan-simulated separation; no
   separate "colour-blind mode" toggle. Confirm (a toggle adds a mode that
   changes allocations, which fights stability).
7. **Stable project key dependency** – projects are display strings today
   (`WorkTask.project` is a title). Project colour records need the same
   backend-qualified project key the billable-flag spec
   (2026-07-06-billable-flag-multibackend.md) requires. Confirm the two
   specs share that one piece of plumbing, whichever builds first.

## 1. What the code says today (investigation)

- **Per-task hash palette.** `AppController.colour(for:)`
  (Sources/andeyeTTMac/AppController.swift:1476-1486): user override from
  `settings.taskColours[ref.storageKey]` (hex), else a djb2 hash of
  `String(describing: ref)` → `hue = hash % 360`, fixed S 0.55 / B 0.85.
  Stable per ref, but hues land anywhere – two projects can collide, and
  there is no notion of "project colour" at all.
- **Override storage is a settings dict.** `AndeyeSettings.taskColours:
  [String: String]` (Sources/andeyeTTCore/Settings.swift:91), saved inside
  settings.json – not a first-class record like pins, which live in their
  own pins.json via `JSONFileStore` (AppController.swift:205-209).
- **The project ring borrows a child's colour.** The pie's project wedge
  takes the colour of its FIRST child task, else an index-based hue
  (SpentView.swift:560-566) – so a project's apparent colour changes when
  its biggest task changes or the sort order shifts. Direct violation of
  stability, today.
- **Ring 3 (windows/apps) derives from the task.** App wedges are the task
  colour at alternating opacity (SpentView.swift:338); no per-surface
  assignment exists.
- **Editing exists in exactly one place.** A `ColorPicker` inside the
  timeline slice editor (Sources/andeyeTTUI/TimelineView.swift:840-844)
  calls `setColour` (AppController.swift:1488-1499, hex + registerUndo).
  Pie legend swatches (SpentView.swift:581-599) are not editable – the row
  button pins/expands the project.
- **Adoption already promises colour carry-over.** Reassociating a local
  task to a remote one keeps its id "so its history, colour and learned
  associations all carry over" (AppController.swift:410) – the new store
  must keep that promise across the storageKey change.
- **Period presets are a closed enum.** `TimePeriod`
  (Sources/andeyeTTCore/TimePeriod.swift:6-10): today / thisWeek / last7 /
  thisMonth; the segmented picker below the pie's calendar iterates
  `allCases` (SpentView.swift:216-223), so a new case appears there
  automatically, to the right of "Month".

## 2. Governing principle – colour stability

A colour assignment is created the first time an item is RENDERED, and
from then on it is data, not derivation:

- First sight commits the allocator's pick to the store (subject key,
  value, provenance `auto`, firstSeen timestamp). `colour(for:)` becomes a
  pure store lookup after that; the hash fallback is retired.
- Renames keep colour: records key on stable identity
  (`TaskRef.storageKey`, backend-qualified project key, pin-style surface
  identity) – never on labels.
- Local→remote adoption migrates the record to the new key in the same
  gesture, honouring the existing carry-over promise.
- New items never displace old ones: the allocator only ever reads
  existing assignments, it never rewrites them. Crowding is absorbed by
  the new item, not redistributed onto seen colours.
- The only things that change a seen colour are the user's own edit and
  its undo.

## 3. The colour model – project hues, task ramps, window shades

All colour maths happens in OKLCH (perceptual – equal steps look equal).

- **Projects own hues.** Each project gets a hue H at an anchor chroma and
  lightness band tuned to read on both light and dark UI. Allocation: score
  a candidate wheel (5° steps) by minimum distance to every existing
  project colour and take the argmax – "the most distinct-from-neighbours
  free hue". Distance is CVD-aware (see the accessibility section), so two
  hues a deuteranope cannot separate are never "distinct".
- **Tasks shade within the project's spectrum.** A task inheriting its
  project renders the project hue at a ramp step: a fixed ladder of
  lightness/chroma pairs ordered so adjacent steps are maximally separated
  (e.g. mid, light, dark, lighter, darker…), with a small bounded hue
  jitter (±8°) for depth. The ramp INDEX is assigned at first sight and
  persisted – it never re-derives from sort order, so a task's shade
  survives its siblings coming and going.
- **Sub-projects and subtasks** take the next ramp step under their
  parent's effective colour, same first-sight/persist rule.
- **Windows/apps** inherit the task's effective colour with the current
  alternating-shade treatment by default; a fixed override (keyed by pin
  identity, open question 5) wins when set.

## 4. Inheritance – fixed or inherit, marked in the swatch

Mirrors the billable flag's tri-state: every non-root item is `inherit`
(default) or `fixed`. Effective colour = own record if fixed, else the
parent's effective colour shaded by the item's persisted ramp step.

- An inheriting item's swatch carries a small "i" marker (corner glyph),
  so a glance tells you whether editing here changes one item or you
  should walk up and edit the parent.
- The swatch editor offers both: "set colour here" (flips to fixed) and
  "edit <parent> colour" (jumps up a level). Clearing a fixed colour
  returns to inherit – the ramp step is still persisted, so the item goes
  back to exactly the shade it had before, not a new one.
- Changing a PROJECT colour moves its inheriting descendants with it (that
  is the point of inheritance); fixed descendants stay put. This is the
  one sanctioned way a seen colour family shifts, because the user did it.

## 5. Editing – click a swatch, anywhere

Every swatch becomes the colour editor: pie legend project and task rows
(SpentView.swift:610/628), the ring-3 window wedges' legend entries, and
the existing timeline editor picker stays. The editor is a small popover:
native colour picker, the inherit/fixed switch, the "i" state, and a
"suggest" button that re-runs the allocator for THIS item only (commits as
a user edit – stability is about the system not moving colours, not about
forbidding the user a fresh pick). All edits go through
`setColour`-style undo registration (AppController.swift:1490 precedent).

## 6. Persistence – colour assignments are records, like pin rules

A dedicated `colours.json` beside pins.json, via the same `JSONFileStore`
(AppController.swift:205-209 pattern) – human-readable, user-ownable,
backupable and diffable exactly like pin rules. One record per assignment:

- `id` (UUID), `subject` (project key | task storageKey | surface
  identity), `value` (hue + ramp step for auto records; hex for user
  picks), `mode` (auto | fixed | inherit-step), `provenance` (auto |
  user), `firstSeen`.

Sync: whole-record LWW like `Pin`/`LocalTaskDef` per the 2026-07-02 sync
design – low churn, no field merging needed. Migration at first launch:
`settings.taskColours` entries become user-fixed records; tasks with
journal time snapshot their hash colour as auto records (open question 3);
the settings dict is then read-only legacy, dropped after one release
(pins.json legacy migration precedent, AppController.swift:235-239).

## 7. Allocation, collisions, redistribution

- **New project**: argmax-min-distance over the candidate wheel against
  all existing project records. With 0 records the anchor hue is fixed
  (deterministic first colour); with N records the gaps halve gracefully –
  golden-angle-like spacing falls out of the argmax without ever moving an
  existing hue.
- **Hue exhaustion**: when the best free hue's minimum distance drops
  below the legibility threshold, the allocator does NOT touch old
  colours; it opens a second lightness band and allocates new projects
  there (same hue wheel, offset L), doubling capacity. Borders and the
  legend carry the remaining difference.
- **No automatic redistribution, ever.** Deleting a project frees its hue
  for FUTURE allocation only. Re-spread is user-only if it exists at all
  (open question 2).
- **Determinism**: the allocator is a pure function of the stored records
  – same store, same answer, on every device and after every restart.
  Checks can drive it headlessly.

## 8. The Life view – colouring the whole estate from the pie

- New `TimePeriod` case `life = "Life"` after `thisMonth`
  (TimePeriod.swift:10); the segmented picker shows it right of "Month"
  automatically (SpentView.swift:216-223). Range: the journal's earliest
  recorded instant → now. Keyboard: ⌘5, alongside ⌘1-4.
- A scope filter appears with it: **All | Tracked | Untracked**. Tracked
  is today's behaviour (aggregated journal time). Untracked lists known
  tasks with zero time in range – they cannot hold wedge area, so they
  render as legend-only rows below the pie, swatches fully editable. All
  shows both. The point: one screen where every project and task andeye
  has ever known can be seen and coloured, so the estate's palette is
  settable in one sitting.
- Performance: Life aggregates the whole journal – it reuses the cached
  `reloadNodes` path (SpentView.swift:153) and must not regress the 1 Hz
  re-render fix noted there; an earliest-date journal query gets an index
  if profiling says so.

## 9. Accessibility

- **Label contrast**: the existing black-or-white label choice
  (SpentView.swift:416, TimelineView.swift:699) stays; auto colours
  constrain L to a band where the chosen label colour always reaches
  4.5:1, in both light and dark themes.
- **Background separation**: wedges sit on `windowBackgroundColor`; auto
  colours keep a minimum lightness delta from both theme backgrounds so
  slices never dissolve into the dark UI.
- **Colour-blind-safe distance**: the allocator's metric is the MINIMUM of
  perceptual distance under identity and protanopia / deuteranopia /
  tritanopia simulation (Machado matrices) – a hue pair is only as
  distinct as its worst-case viewer. Existing non-colour channels (dashed
  local borders, SpentView.swift:586; the "i" marker; labels) remain so
  colour is never the sole signal.

## 10. Acceptance criteria

- Adding project N+1 changes ZERO existing assignments (store diff is one
  new record) – checked headlessly in andeyeTTChecks by driving the
  allocator over a growing store.
- For 2…12 projects allocated in sequence, every pairwise CVD-aware
  distance meets the legibility threshold; beyond capacity the second
  lightness band engages and old records still never move.
- Rename a task or project: effective colour byte-identical before/after.
- Local→remote adoption: colour record migrates with the key; effective
  colour unchanged.
- Restart and store round-trip: `colour(for:)` returns identical values;
  the hash fallback is unreachable for any item in the store.
- Swatch click opens the editor everywhere a swatch renders; inheriting
  swatches show the "i"; fixing then clearing returns the pre-edit shade;
  every edit is undoable.
- "Life" appears right of "Month", spans first-journal-entry → now;
  Untracked lists zero-time known tasks with editable swatches; All =
  Tracked ∪ Untracked.
- Every auto colour passes 4.5:1 label contrast in both themes (checked
  numerically over the full ramp).
- Migration: pre-existing `taskColours` overrides and every task with
  journal time keep exactly the colour they showed before the upgrade.

## Timeline edits and learning – answers (6 Jul)

**(a) Does the system learn from Timeline edits?** Partly. Reassigning a
slice to a different task DOES teach the attributor; changing only a
slice's start/end time does NOT. The timeline's save path is
`applyTimelineEdit` (Sources/andeyeTTMac/AppController.swift:1714, called
from Sources/andeyeTTUI/TimelineView.swift:997/1003); it only calls the
learning hop `teachAssociation` when the task actually changed – the guard
`if let previous, previous.task != session.task` at AppController.swift:1727
– so a pure retime falls straight through to journal update, backend
`updateTimeEntry` and the summary refresh, touching no learning at all. The
reassign paths do learn: whole-slice reassign (`reassignTimelineSessions`,
AppController.swift:1807, teaching at :1832, from TimelineView.swift:723)
and per-window reassign via the Evidence Card (`splitAndReassign`,
AppController.swift:1946 → `replaceSession` teaching each moved piece at
:1941, from TimelineView.swift:1149/1197). `teachAssociation`
(AppController.swift:1770) feeds `attributor.assign(dominantSignal,
target: .task(...))`.

**(b) Is there a priority ordering between retime vs slice-reassign vs
window-reassign?** No. Retiming teaches nothing (above), and the two
reassign kinds land on the identical mechanism at the identical strength:
`Attributor.assign` (Sources/andeyeTTCore/Attributor.swift:359) records a
sticky plus a weight-2 soft prime, capped at the 0.95 inferred ceiling
(Attributor.swift:150). Whole slice or single window – same code path,
same weight 2. The heavier weights that exist in the codebase (Boost =
weight 4, AppController.swift:1462; pin ≈ weight 6 or a true 100 % pin,
AppController.swift:1467) belong to the why-panel and pin editor, not to
any timeline edit.

**(c) Does a live popover correction outrank timeline edits?** No – equal
strength. The popover pick (Sources/andeyeTTUI/PopoverView.swift:784/788)
goes through `changeCurrentTask` (AppController.swift:1009) or `userPicked`
(AppController.swift:875) → `tracker.confirm` →
`attributor.confirm` (SessionTracker.swift:254 → Attributor.swift:342),
which is the same sticky + weight-2 `learnSurface` the reassign paths
produce. Live correction and timeline reassign are peers in the learner;
only an explicit pin (score 1.0, above the 0.95 ceiling) or the Boost
button outranks either, and neither the popover pick nor a timeline edit
creates one.

**(d) Plainly:** retiming a slice's start/end never learns – it is pure
journal/backend rewriting; and among the actions that DO learn (slice
reassign, window reassign, live popover correction) there is no ordering
at all – all three are weight-2, 0.95-capped soft primes. Deleting a
timeline slice also teaches nothing; the one timeline action with special
learning is "don't track this" (`markSessionDoNotTrack`,
AppController.swift:1780), which assigns the surface to `.doNotTrack`
at the same weight.

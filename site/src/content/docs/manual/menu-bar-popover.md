---
title: The menu-bar popover
description: The everyday Time&I surface – current task, elapsed time, the pin chip, and the task list.
---

Click the Time&I icon in the menu bar to open the popover. The icon is the
&I mark plus the current elapsed time; the mark's colour reflects how certain
the attribution is (red = uncertain, green = certain, both tunable in
[Settings ▸ Menu bar](/manual/settings/)). Two optional looks live there
too: **Draw in certainty** strokes only part of the mark - just the eye when
Time&I is unsure, growing to the whole &I as certainty rises - and
**Monochrome menu bar** renders the item like macOS's own status items (no
colour signalling).

At the top:

- **Current task** - the task the running time is being filed against, in bold.
  Clicking it flips the task list below between "Switch to" and "Reassign" (see
  below). A quiet "← <previous task>" button appears beside it when the last
  switch looks wrong - one click folds the current slice back onto that task.
- **Elapsed + certainty** - the time on the current contiguous session and, when
  not pinned, how certain andeye is. A **£ glyph** after a task name (here and
  in the pick list) means its time is billable - from the task's own setting,
  or its project's.
- **Pin chip** - when the surface is pinned you see a pin icon and the pinned
  scope. Click it to adjust or remove the pin.
- **Pin button** (when not pinned, ⌘P), **Away** (keep tracking while you step
  away, ⌘⇧L), and **Stop** (⌘.).
- **Note field** - type a comment and press ↵ to commit it (flashes green); a
  slice can carry several, each ↵ adding another. It accumulates onto the
  current time slice's own comment and, when Settings sends comments to the
  task too, posts to the DISPLAYED task's activity feed immediately - what
  you see commented is what gets commented, even if the tracked task changes
  a moment later.

The task list:

- **Switch to / Reassign.** "Switch to" starts a fresh session on the task you
  pick. "Reassign" moves the time you've spent on the CURRENT tab or window
  to the task you pick - time on earlier windows in the session stays where
  it was tracked, banked as its own entry. When those two figures differ, the
  mode label shows both ("moves 1m on this tab · 10m total") so the scope is
  clear before you click; the menu-bar clock keeps showing the running
  total. Which mode is the default when you open the popover is a Setting;
  clicking the current task title flips to the other for that open.
- **Filter / search.** The field is focused when the popover opens, so you can
  type immediately. With it empty the list shows your recent and likely tasks
  first, then everything else, all scrollable. Typing fuzzy-searches every task.
- **Resume / idle gap.** When stopped, a "Resume <last task>" button restarts the
  clock. After an idle stretch a one-tap "Worked <time> on <task>?" offer lets
  you claim the gap as work. An idle stop also un-sticks itself: come back
  within half an hour and tracking resumes by itself - to whatever the screen
  says if that's clear, otherwise to the task you were on (flagged for review
  if andeye wasn't sure). A manual stop never restarts on its own.
- **Right-click a task** - open it in your backend, or Comments… for its
  local comment history (notes typed in the comment bar land there whenever
  they can't, or shouldn't, go to a backend feed).

The footer:

- **Donut button** (⌘Y) - a live mini-donut of today's breakdown. Click it to
  open the Time window (see [The Time window](/manual/time-window/)).
- **Review queue** (⌘U), **Settings** (⌘,), **Quit** (⌘Q).

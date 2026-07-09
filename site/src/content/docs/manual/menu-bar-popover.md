---
title: The menu-bar popover
description: The everyday andeye surface – current task, elapsed time, the pin chip, and the task list.
---

Click the andeye icon in the menu bar to open the popover. The icon itself
shows the current elapsed time, and a small coloured dot whose colour reflects
how certain the attribution is (red = uncertain, green = certain).

At the top:

- **Current task** - the task the running time is being filed against, in bold.
  Clicking it flips the task list below between "Switch to" and "Change to" (see
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

- **Switch to / Change to.** "Switch to" starts a fresh session on the task you
  pick. "Change to" relabels the session you're already on (keeps the elapsed
  time, moves it to the right task). Which one is the default when you open the
  popover is a Setting; clicking the current task title flips to the other for
  that open.
- **Filter / search.** The field is focused when the popover opens, so you can
  type immediately. With it empty the list shows your recent and likely tasks
  first, then everything else, all scrollable. Typing fuzzy-searches every task.
- **Resume / idle gap.** When stopped, a "Resume <last task>" button restarts the
  clock. After an idle stretch a one-tap "Worked <time> on <task>?" offer lets
  you claim the gap as work.
- **Right-click a task** - open it in your backend, or Comments… for its
  local comment history (notes typed in the comment bar land there whenever
  they can't, or shouldn't, go to a backend feed).

The footer:

- **Time** (⌘Y) - a live mini-pie of today's breakdown. Click it to open the Time
  window (see [The Time window](/manual/time-window/)).
- **Review queue** (⌘U), **Settings** (⌘,), **Quit** (⌘Q).

---
title: The Time window
description: The timeline and pie views of your tracked time, and how to edit it.
---

One window shows your time two ways - a **timeline** and a **pie** - and you flip
between them in place. The footer pie in the popover opens it on the timeline,
the pie, or whichever you viewed last, per a Setting. Like every Time&I
window, it appears over full-screen apps and settles onto whichever desktop
you're working on.

## Switching views

There is no separate switcher button: the cross-previews are the navigation.

- In the **timeline**, the top-right mini-pie is today's breakdown. **Click it**
  to flip this window to the pie.
- In the **pie**, the "from HH:MM" strip is the current block's timeline. **Click
  a slice** to flip to the timeline framed on (and editing) that exact slice;
  **click a gap or the "from" label** to open the timeline with nothing selected.

**⌘\\** flips between the two views from the keyboard. To see both at once,
**Billable flags** (pie view): right-click a project or task to mark it
billable or non-billable (tasks can also inherit from their project);
billable rows carry a "billable" label in the legend. Marking a project
billable warns you about already-tracked hours that will NOT be invoiced
(flips apply to new time only) and leaves manually-set tasks as they were.

**⌃-click (or right-click)** a preview - that opens the other view in a *second*
Time window instead of flipping the current one.

## Timeline view

A continuous, absolute-time bar that pans and zooms freely, including across
midnight. Day boundaries are marked with the date.

- **Pan**: two-finger scroll, the ‹ › buttons, or ⌘[ / ⌘] (a day at a time).
  **Zoom**: pinch, the ± buttons, or ⌘− / ⌘+ - zoom homes in on the time under the
  cursor. **Block** (⌘B) frames the latest run of work; **Today** (⌘0) shows
  midnight to now.
- **Edit a slice**: click it to open the editor (task, start, end, duration,
  comment, colour). Drag a slice's edge handles to resize; dragging over a
  neighbour eats into it.
- **Comments**: a slice with a comment carries a small bubble mark, and its
  hover tooltip shows the text. The ongoing slice shows its comments the
  moment you commit them; earlier comments already saved under it appear
  read-only in its editor, next to the note you can still edit. Slices that
  merge keep both comments, joined.
- **Create**: drag on empty space to draw a slice, or click a gap to fill it.
- **Overlaps**: editing an end over a neighbour offers two resolutions - **Snap
  to windows** (↵, default) moves the boundary to the nearest tracked-window edge
  so each window lands wholly on one task, or **Exact time** (space) keeps the
  time you typed.
- **Delete**: select slice(s) and press delete/backspace, or use the Delete
  button on the reassign bar. ⌘-click and ⇧⌘-click multi-select like Finder.
- **Billable**: right-click a slice to mark just that entry billable or
  non-billable - an entry's own mark beats its task's and project's settings
  both ways, and it alone decides whether that entry invoices; **Inherit**
  hands the decision back to the task and project. The same menu offers
  **Billable: whole task** and **Billable: whole project**, which mark the
  clicked entry and set the task or project billable for future time in one
  undoable step. The slice editor's footer shows the entry's billable state.
- **Allocate a stretch**: shift-drag (or shift-click, then shift-click again to
  extend) selects a time range, shown as a translucent band with its start and
  end - it isn't bound to any slice's edges, so it can cut straight through
  the middle of one. A small bar then offers **Allocate…** (pick a task) or
  **Unknown**; a slice only partly inside the range is split at its edge, the
  rest stays as it was. Esc or clicking empty space clears the selection.
- **Detail strip**: the windows inside the selected slice, with the "why" panel
  described in [Auto-tracking and attribution](/manual/auto-tracking-and-attribution/).
  Move windows to another task to split/reassign and teach the learner.

## Pie view

- **Period** (Today ⌘1 / Week ⌘2 / Last 7 days ⌘3 / Month ⌘4), with an
  "OpenProject only" filter (⌘⇧O) and a show/hide calendar (⌘⇧C).
- A donut: projects in the inner ring, tasks in the outer. Hover to highlight,
  click to pin a selection; reassign time to another task from the bar.
- **Colours**: each project gets its own hue, and its tasks distinct shades
  around it - picked to stay tellable-apart (including under colour-blind
  vision) and never reshuffled: once a task has shown its colour, it keeps
  it. **Click any legend swatch** to choose your own colour for that project
  or task (Reset to automatic hands the choice back); your pick always wins,
  and a recoloured project guides the shades its future tasks pick up. The
  timeline's slice editor and a local task's Settings row offer the same
  picker.

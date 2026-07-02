# andeye - User Manual

andeye is a macOS menu-bar app that tracks where your time goes and files it
against your OpenProject work packages (it calls them "tasks") automatically. It
watches which window, app or browser tab is in front, attributes the time to the
most likely task, and learns from your corrections so it asks less over time.
Everything lives on your Mac (a local SQLite journal); the only thing that
leaves is a push to your own OpenProject, plus an AI assist you trigger yourself.

This manual covers day-to-day use. For building and first-run setup see
`README.md`.

## The menu-bar popover

Click the andeye icon in the menu bar to open the popover. The icon itself
shows the current elapsed time, and a small coloured dot whose colour reflects
how certain the attribution is (red = uncertain, green = certain).

At the top:

- **Current task** - the task the running time is being filed against, in bold.
  Clicking it flips the task list below between "Switch to" and "Change to" (see
  below). A quiet "← <previous task>" button appears beside it when the last
  switch looks wrong - one click folds the current slice back onto that task.
- **Elapsed + certainty** - the time on the current contiguous session and, when
  not pinned, how certain andeye is.
- **Pin chip** - when the surface is pinned you see a pin icon and the pinned
  scope. Click it to adjust or remove the pin.
- **Pin button** (when not pinned, ⌘P), **Away** (keep tracking while you step
  away, ⌘⇧L), and **Stop** (⌘.).
- **Note field** - a comment for the current task's time; where it goes is set in
  Settings (the time entry and/or the task's activity feed).

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

The footer:

- **Time** (⌘Y) - a live mini-pie of today's breakdown. Click it to open the Time
  window (see below).
- **Review queue** (⌘U), **Settings** (⌘,), **Quit** (⌘Q).

## Auto-tracking and attribution

Every time the front window, app or tab changes, andeye scores the candidate
tasks and tracks the best one. Sources, strongest first:

1. An explicit **pin** (always 100%).
2. An **OpenProject task URL** in the browser tab (or a work-package id in the
   window title).
3. A **just-opened OP task** priming the next surface you work on.
4. A **remembered surface** from a past correction.
5. **Learned associations** (what you've confirmed before) plus status/recency
   priors.

A brief flit to another window does not immediately re-file your time: a switch
only becomes its own slice once you've held it past the Switch Buffer (and never
below one displayed minute), so glancing at Slack mid-task does not fragment your
timeline.

### Why was this tracked as X?

Open the Time window's timeline, click a slice, then click a window in its detail
strip. The pane explains the decision: the source (pinned / OP URL / remembered /
learned, etc.), the candidate tasks with each score split into its learned and
prior parts, and the exact signal features the learner keys on (app, title
words, URL host). To fix future tracking, move that window to the right task in
the strip below - that teaches the learner, so the window files correctly next
time.

## Pinning

A pin says "this surface is ALWAYS this task" at 100%, overriding everything
else. Click the pin button in the popover to open the pin editor.

- **Components** (the default) - the captured identity is shown broad to narrow
  (host then path for a URL; app then window-name parts for an app). Blue parts
  are pinned, grey are not. Click a part, or use ← / → , to widen or narrow the
  scope. App pins default to app + window name and match on PRESENCE, so a pinned
  terminal window keeps matching even when the terminal prepends its mode to the
  title.
- **Expression** (via the hamburger menu) - a typed boolean rule. Fields: `app`,
  `title`, `url`, `sender` (alias `from`), `subject`, `any`. Operators: `is`,
  `contains`, `starts with`, `matches` (regex). Logic: `and`, `or`, `not`,
  parentheses. Negation reads naturally too (`app is not "Ghostty"`, `url does
  not contain "github"`). `from`/`sender` match the email correspondents and
  `subject` the email subject (so `from contains "harborlane.example"` pins all
  mail to/from that company); `any` — and bare text with no field — searches
  every field including the correspondents and subject. A parse error shows in
  full above the buttons.
- **AI** (via the hamburger menu) - for a window whose own app/title/url don't
  obviously say which task it is. It builds a prompt from the captured fields plus
  an editable guidance box (pre-seeded to prefer a stable pattern over a volatile
  title), copies it to the clipboard for you to paste into any AI, and takes the
  reply back: paste the rule it returns and ↵ turns it into an ordinary, editable
  Expression rule (or shows a parse error). When a typed Expression won't parse,
  a **Fix with AI** button hands the failed rule straight to this mode.
- **Enter** pins. The **✕** (or esc) means "no pin here": it unpins when you
  opened on an existing pin, or drops a never-saved draft.

## The Time window

One window shows your time two ways - a **timeline** and a **pie** - and you flip
between them in place. The footer pie in the popover opens it on the timeline,
the pie, or whichever you viewed last, per a Setting.

### Switching views

There is no separate switcher button: the cross-previews are the navigation.

- In the **timeline**, the top-right mini-pie is today's breakdown. **Click it**
  to flip this window to the pie.
- In the **pie**, the "from HH:MM" strip is the current block's timeline. **Click
  a slice** to flip to the timeline framed on (and editing) that exact slice;
  **click a gap or the "from" label** to open the timeline with nothing selected.

**⌘\\** flips between the two views from the keyboard. To see both at once,
**⌃-click (or right-click)** a preview - that opens the other view in a *second*
Time window instead of flipping the current one.

### Timeline view

A continuous, absolute-time bar that pans and zooms freely, including across
midnight. Day boundaries are marked with the date.

- **Pan**: two-finger scroll, the ‹ › buttons, or ⌘[ / ⌘] (a day at a time).
  **Zoom**: pinch, the ± buttons, or ⌘− / ⌘+ - zoom homes in on the time under the
  cursor. **Block** (⌘B) frames the latest run of work; **Today** (⌘0) shows
  midnight to now.
- **Edit a slice**: click it to open the editor (task, start, end, duration,
  comment, colour). Drag a slice's edge handles to resize; dragging over a
  neighbour eats into it.
- **Create**: drag on empty space to draw a slice, or click a gap to fill it.
- **Overlaps**: editing an end over a neighbour offers two resolutions - **Snap
  to windows** (↵, default) moves the boundary to the nearest tracked-window edge
  so each window lands wholly on one task, or **Exact time** (space) keeps the
  time you typed.
- **Delete**: select slice(s) and press delete/backspace, or use the Delete
  button on the reassign bar. ⌘-click and ⇧-click multi-select like Finder.
- **Detail strip**: the windows inside the selected slice, with the "why" panel
  described above. Move windows to another task to split/reassign and teach the
  learner.

### Pie view

- **Period** (Today ⌘1 / Week ⌘2 / Last 7 days ⌘3 / Month ⌘4), with an
  "OpenProject only" filter (⌘⇧O) and a show/hide calendar (⌘⇧C).
- A donut: projects in the inner ring, tasks in the outer. Hover to highlight,
  click to pin a selection; reassign time to another task from the bar.

## Settings

- **Comments** - whether a note goes to the time entry, the task's feed, or both.
- **Popover default mode** - "Change to" (default) or "Switch to".
- **Time button opens** - Timeline / Last viewed / Pie chart.
- **Switch Buffer** and grace windows, idle and sleep handling.
- **System notifications**, **lock on leave**, **track leisure to local tasks**.
- **Local tasks** - personal non-OP tasks (e.g. "Chess") you can track against.
- **OpenProject** - base URL and API key.

## Data, sync and safety

- Your time is journalled to a local SQLite database; that is the source of
  truth. Confident OP tasks push to your OpenProject automatically (above a
  certainty threshold you set).
- The OP API key is stored in an owner-only (0600) file in the app support
  folder, not the Keychain.
- A crash-safe checkpoint means a hard crash loses at most a short tail of the
  current session.

## Keyboard

Every action can be done with the mouse. The everyday surfaces - the popover and
the Time window - also have keyboard shortcuts, shown below and in each control's
tooltip. Settings and the Review queue are standard macOS forms: move with **Tab**
/ **⇧Tab**, toggle with **Space**, open pop-ups and steppers with the arrow keys
(turn on *System Settings ▸ Keyboard ▸ Keyboard navigation* to Tab onto every
control). Each shortcut works while that window (or the popover) is frontmost.

### Global (from any app)

- **⌘⇧L** - I'm leaving my desk (away) / I'm back.
- **⌘Z** - undo the last task switch (fold the current slice back to the previous
  task).

### Popover

- **⌘T** - flip the list between Switch-to and Change-to.
- **⌘P** - pin the current window/site (or, when pinned, open the pin editor).
- **⌘.** - stop tracking. **⌘R** - resume the last task.
- **⌘Z** - back to the previous task (same as the quiet ← button).
- **↵** in the filter - pick the top task in the list.
- **⌘↵** - claim the "you were away" idle gap as work.
- **⌘Y** - open the Time window. **⌘U** - open the Review queue.
- **⌘,** - Settings. **⌘Q** - quit andeye.

### Pin editor

- **← / →** - widen / narrow the pinned scope (Components mode).
- **↵** - pin. **Esc** - no pin here (unpins an existing pin, or drops a draft).

### Time window - both views

- **⌘\\** - flip between the timeline and the pie.
- **⌃-click** (or right-click) a preview - open the *other* view in a second
  window instead of flipping.

### Time window - timeline

- **⌘[ / ⌘]** - pan back / forward a day.
- **⌘− / ⌘+** - zoom out / in (zoom homes in on the time under the cursor).
- **⌘B** - frame the latest block of work. **⌘0** - today, midnight to now.
- **← / →** - select the previous / next slice; **⇧** extends the selection;
  **↵** opens the editor on the selected slice.
- **⌘-click / ⇧-click** - multi-select slices (toggle / range), like Finder.
- **delete / backspace** - delete the selected slice(s).
- In the slice editor: **↵** saves (when resolving an overlap, ↵ = *Snap to
  windows*, **Space** = *Exact time*); **Esc** closes; **⌘⌫** deletes the slice.
- In a slice's window strip: **⌘A** - select every window in the slice.

### Time window - pie

- **⌘1 / ⌘2 / ⌘3 / ⌘4** - period Today / Week / Last 7 days / Month.
- **⌘⇧O** - toggle "OpenProject only". **⌘⇧C** - show / hide the calendar.
- **⌘[ / ⌘]** - previous / next month in the calendar.
- In the calendar: click a day to snap the period's width onto it; drag, or
  shift-click, to select an arbitrary span.

### Review queue

- **⌘D** - mark the selection as "do not track".
- **↵** in the task filter - assign the selection to the top task.
- **⌘⇧C** - copy the AI prompt. **⌘↵** - apply a pasted AI response.

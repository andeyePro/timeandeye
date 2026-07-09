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

### Context rules: see why, un-learn in one click

In the popover, the certainty line grows a "why?" suffix whenever a signal is
tracking (**⌘E**, or click it) - it expands the Evidence Card in place. In the
Time window's timeline, click a slice then a window in its detail strip to see
the same card full-size.

The card shows, top to bottom:

- **BECAUSE** - the source that fired (pinned, a learned email rule,
  remembered, learned associations...), with the rule's provenance when one
  fired (when it was learned, how many times it's fired). If something LEARNED
  drove the decision, a **✕ forget** (or **✕ suppress** for a learned
  association, which can't be deleted outright, only counter-taught) removes
  exactly that - undoable (⌘Z) - and shows what would fire instead BEFORE you
  click.
- **sees:** - the evidence andeye actually captured: app and site/title
  always, plus the correspondent, domain and subject when the surface is an
  email. A field it didn't capture shows as "not captured", never hidden.
- **Wrong? file as** - search for the right task, then choose how durably to
  fix it: **Once** (today, this thread - today's soft correction, no lasting
  rule), **Remember** (a revisable rule at the grain you pick - correspondent,
  domain, subject or the whole mail system), or **Always 📌** (a pinned rule,
  100% and standing law).

Picking a task from the popover's own list on an email surface also offers a
one-line "remember for..." footer underneath - the same Remember, without
opening the card. The Review queue offers the same footer under its assign
bar: assign a batch of low-certainty windows to one task and, when every row
in the batch shares one email context, the identical one-line Remember offer
appears there too. Either place, when that context has more than one
correspondent, checking the correspondent row expands it into a checkbox per
address, so you choose exactly who the rule should cover, not just the first
one andeye saw.

Can't place a batch at all? The assign bar's **Not sure - Unknown** button
sweeps it to the built-in Unknown task instead of "Do not track" or a guess -
the time stays tracked with full detail, just off your review queue. It shows
up hatched grey on the timeline and in the pie so it's never mistaken for a
real task, and you can reassign it from the timeline any time you do work out
what it was. If a later rule makes andeye confident about it on its own, it
reclaims itself back out of Unknown automatically.

Saving a rule shows a brief "✉ who → task" notice with an Undo, and the first
time a learned rule goes on to fire for real, you're told once more, so a
decision it makes on your behalf is never silent. Both notices sit in the
popover, auto-dismiss on their own, and are never a system notification.

Every learned + pinned email rule lives in **Settings ▸ Email → task
matching ▸ Context rules…**, listed with its provenance. Click a row for its
full detail; forget it there, or forget a whole task's rules at once with its
group's **Forget all** button - either way, one undo (⌘Z) restores everything
that click removed. **Copy rules** puts the lot on the clipboard as plain
text.

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
- **Billable flags**: right-click a project or task to mark it billable or
  non-billable (tasks can also inherit from their project); billable rows
  carry a "billable" label in the legend. Marking a project billable warns
  you about already-tracked hours that will NOT be invoiced (flips apply to
  new time only) and leaves manually-set tasks as they were.

## Settings

- **Comments** - whether a note goes to the time entry, the task's feed, or both.
- **Popover default mode** - "Change to" (default) or "Switch to".
- **Time button opens** - Timeline / Last viewed / Pie chart.
- **Switch Buffer** and grace windows, idle and sleep handling.
- **System notifications**, **lock on leave**, **track leisure to local tasks**.
- **Idle backfill** - opt-in: when you return from an idle gap, offer to
  claim the gap for the task you were on (off by default; hours stepper caps
  how far back it offers).
- **Local tasks** - personal non-OP tasks (e.g. "Chess") you can track against.
- **OpenProject** - base URL and API key.
- **Licence** - the app is complete without one; a licence only adds paid
  connectors. Paste a key (`ANDEYE1.` followed by two dot-separated blocks)
  and Apply: the tier (Plus / Pro / Premium / Enterprise), who it is licensed
  to, and the renewal date appear - lifetime keys show "lifetime". If the key
  can't be used, the reason appears in red below the field.
- **Posting health** - appears only when something needs you: per backend, a
  count of entries stuck after repeated failures (with a one-click Retry) and
  a count of entries that disagree with your journal and can't be fixed
  automatically (usually because they're locked into an invoice). Ordinary
  edits and deletions of already-posted time propagate to the backend on
  their own within a minute or two.
- **Duplicate reconcile** - scans for OpenProject time entries logged twice
  against the same task and minute. Click a match to see every difference
  between its entries, then Apply: the richest entry survives (the others'
  comments fold into it), the rest are deleted, and your journal re-points to
  the survivor - confirm each. Each entry's ↗ opens that task's time-entries
  report in OpenProject, so you can check anything not shown here (custom
  fields, say) before deleting.
- **iCloud footprint** - a live readout of what your synced journal (and,
  separately, your local-only window detail) is costing you in your private
  CloudKit database - typically a few hundred bytes a slice, 15-25 MB a year
  of heavy tracking; nobody gets pushed into a paid iCloud tier by andeye.
- **Consolidate old history** - collapses slices older than a number of years
  you choose into daily totals. Totals and invoicing history survive exactly
  - only the minute-by-minute detail goes.
- **Hard cap - strongly discouraged** - deletes your oldest raw slices,
  double-confirmed and with no undo, until the synced journal is back under a
  size you pick. Old totals can be lost for good; it's for a genuine
  iCloud-quota emergency only, since the synced journal is normally tiny (see
  iCloud footprint above).
- **Email → task matching** - your own addresses/domains (comma-separated),
  so andeye never mistakes you for the other party when a message's
  correspondent decides the task; see Auto-tracking and attribution above
  for the rules themselves.
- **Currency symbol** - shown wherever billable totals render; leave blank
  for your locale's own symbol.

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

A £ glyph after a task name (in the pick list, and after the running task in
the header) means its time is billable - resolved from the task's own
setting, or its project's.

- **⌘T** - flip the list between Switch-to and Change-to.
- **⌘P** - pin the current window/site (or, when pinned, open the pin editor).
- **⌘E** - open the Evidence Card (why this was tracked here, un-learn, fix).
- **⌘.** - stop tracking. **⌘R** - resume the last task.
- **⌘Z** - back to the previous task (same as the quiet ← button).
- **↵** in the filter - pick the top task in the list.
- **⌘↵** - claim the "you were away" idle gap as work.
- **⌘Y** - open the Time window. **⌘U** - open the Review queue.
- **⌘,** - Settings. **⌘Q** - quit andeye.

### Evidence Card

- Click a grain row (or **↑ / ↓**) to choose how durably to remember the fix.
- **↵** - Remember (a revisable rule at the chosen grain).
- **⇧↵** - Always (a pinned rule, 100%).
- **esc** - Once (today's soft correction only, same as picking a task
  normally).

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

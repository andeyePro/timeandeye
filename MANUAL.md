# Time&I - User Manual

Time&I is a macOS menu-bar app that tracks where your time goes and files it
against your OpenProject work packages (it calls them "tasks") automatically. It
watches which window, app or browser tab is in front, attributes the time to the
most likely task, and learns from your corrections so it asks less over time.
Everything lives on your Mac (a local SQLite journal); the only thing that
leaves is a push to your own OpenProject, plus an AI assist you trigger yourself.

This manual covers day-to-day use. For building and first-run setup see
`README.md`.

## The menu-bar popover

Click the Time&I icon in the menu bar to open the popover. The icon is the
&I mark plus the current elapsed time; the mark's colour reflects how certain
the attribution is (red = uncertain, green = certain, both tunable in
Settings ▸ Menu bar). Two optional looks live there too: **Draw in
certainty** strokes only part of the mark - just the eye when Time&I is
unsure, growing to the whole &I as certainty rises - and **Monochrome menu
bar** renders the item like macOS's own status items (no colour signalling).

At the top:

- **Current task** - the task the running time is being filed against, in bold.
  Clicking it flips the task list below between "Switch to" and "Reassign" (see
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

- **Switch to / Reassign.** "Switch to" starts a fresh session on the task you
  pick. "Reassign" relabels the session you're already on (keeps the elapsed
  time, moves it to the right task). Which one is the default when you open the
  popover is a Setting; clicking the current task title flips to the other for
  that open.
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
  open the Time window (see below).
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

On a web page andeye doesn't recognise at all - no rule, no site it's seen
before - it stays on your current task rather than guessing, and the
certainty reads low (red) until you either teach it (Reassign, which also
teaches the site) or move on. Genuinely new-tab or search pages behave the
same way: the task you were on keeps running.

A brief flit to another window does not immediately re-file your time: a switch
only becomes its own slice once you've held it past the Switch Buffer (and never
below one displayed minute), so glancing at Slack mid-task does not fragment your
timeline.

Turn on **Calendar** in Settings and a meeting that's live right now nudges
that slot in the ranking - never enough to beat a pin, a URL match or a
learned rule, just enough to break a tie among your ordinary tasks. The pick
list marks the matching task with a small clock; if you're tracking
something else during a meeting, the popover offers a one-line
"Calendar: <meeting> - Switch". The menu-bar mark also alerts you around
meetings: it pulses gently through the last few minutes before an event
starts (five by default - pick the lead time in Settings), then flashes
hard the moment the event begins before settling back to normal. Both
alerts can be switched off individually; a meeting already underway when
andeye starts never flashes after the fact, tentative invites pulse but
never flash, and all-day events never alert. The same matching runs over
your calendar history for the Review queue, so an old row that overlaps a
past meeting gets a one-click assign hint too. Corrections teach it a rule
the same way email does, and nothing calendar-derived ever leaves your Mac.

### Context rules: see why, un-learn in one click

In the popover, the certainty line grows a "why?" suffix whenever a signal is
tracking (**⌘E**, or click it) - it expands the Evidence Card in place. In the
Time window's timeline, click a slice then a window in its detail strip to see
the same card full-size.

The card shows, top to bottom:

- **BECAUSE** - the source that fired (pinned, a learned email rule,
  remembered, learned associations...), with the rule's provenance when one
  fired (when it was learned, how many times it's fired). A remembered
  window/site shows the exact remembered key it matched on, so an over-broad
  memory is visible - and forgettable - at a glance. In the timeline, a
  window's slice already stands somewhere in your journal, and the journal
  records what decided it at the moment - so BECAUSE names the original
  decider outright ("you pinned it", "a learned rule fired (✉ …)", "you
  assigned it"). If the rules as they are NOW would file that window
  differently, today's differing read appears beneath, marked "today's
  rules would say" - it is never presented as the reason the slice is
  where it is - with a one-click **↪ refile as…** button when today's
  answer is confident. The engine also acts on its own: slices IT decided
  (never ones you assigned or pinned) refile automatically when a later
  correction or rule confidently contradicts them - batched into the same
  "recently cleared - undo" receipt as the retro pass; already-posted
  entries are flagged in Posting health instead of moved; weaker
  contradictions appear as one "look mis-filed" row in Review with
  refile-all and dismiss. If something LEARNED
  drove the decision, a **✕ forget** (or **✕ suppress** for a learned
  association, which can't be deleted outright, only counter-taught) removes
  exactly that - undoable (⌘Z) - and shows what would fire instead BEFORE you
  click.
- **sees:** - the evidence andeye actually captured: app and site/title
  always, plus the correspondent, domain and subject when the surface is an
  open message in Gmail, Outlook Web, Proton Mail, Yahoo Mail or Fastmail.
  A field it didn't capture shows as "not captured", never hidden.
- **Wrong? file as** - search for the right task, then choose how durably to
  fix it: **Once** (today, this thread - today's soft correction, no lasting
  rule), **Remember** (a revisable rule at the grain you pick - correspondent,
  domain, subject or the whole mail system), or **Always 📌** (a pinned rule,
  100% and standing law).

Picking a task from the popover's own list on an email surface or any web
page also offers a one-line "remember for..." footer underneath - the same
Remember, without opening the card. The Review queue offers the same footer
under its assign bar: queued rows keep the correspondents and subject
captured while their time accrued, so assigning a batch of low-certainty
windows to one task offers the identical Remember - at the correspondent,
domain or subject grain when every row in the batch shares one email
context, at the mail-system grain when the batch only shares the mail
system, or at the whole-site grain when web rows share only their site.
Either place, when that context has more than one
correspondent, checking the correspondent row expands it into a checkbox per
address, so you choose exactly who the rule should cover, not just the first
one andeye saw.

The queue only asks about moments worth a decision: a visit appears once
its slice is at least a minute long (tunable in Settings, "Review queue
floor"). Briefer glances stay tracked and journalled as normal - they just
never queue, however often they repeat - because a moment too brief to
switch tracking is never worth naming.

Selecting works like the Finder: click a visit to select it, or click a
row's header - or the strip down its left edge while it's open - to select
its whole group. ⌘-click adds or removes a row without disturbing the
rest; ⇧-click selects everything between the last row you clicked and this
one, whole groups and single visits alike. A selection mixes freely:
whole groups here, single visits there, across any number of rows.
Clearing a backlog? Sort the queue from the control at the top - newest,
oldest, longest or shortest - then click the top row and shift-click at
the cutoff to select everything in between. One press of
**Clear**, **Unknown** or a task then handles everything selected - so
does ⌫ for Clear - and one ⌘Z brings it all back. **Clear** drops the
selection from the queue without adding it to timesheets and without
teaching andeye anything - the quick way past slices not worth naming;
your timeline and journal keep the time untouched.

Every row is dated - Today, Yesterday or the calendar date - and every row
expands. A row is one *surface* (an app, window or tab), stacking every
separate visit to it; the chevron lists those visits, and each visit's own
chevron reveals everything held on it - exact start and end, duration, app,
window title and address, any email correspondents and subject, how certain
andeye currently is about it and where that certainty comes from, and what
filled the time immediately before and after it (with the gap named when
they weren't back-to-back; a neighbour that is itself still awaiting review
shows in italics as *pending review* with its surface, since nothing is
decided about it yet). **Expand all** in the header (⌘E) opens every stack
and every visit's detail at once - the certainty and neighbour lines fill
in a moment later as they're worked out - and pressing it again collapses.
Because any single visit can be selected on its own, one visit in a stack
can go to a different task than its siblings: select just it and assign.
It leaves its group immediately, and the buttons re-score over the visits
that remain.

Prefer to walk the day instead of selecting? The arrow buttons at the top
of the queue (⌘[ / ⌘], or ← / → while the list has focus) step through
the visits in time order, in either direction - each visit opens as you
land on it and gains an eye mark: *viewed*. Clicking a visit or opening
its detail marks it too; merely scrolling past - or Expand all - never
does, so a mark always means you actually looked. Dig in as deep as you
like on the way; assigning or clearing something mid-walk simply handles
it and the walk carries on. **Confirm viewed** then takes andeye's
current reading of every marked visit as your decision, in one click and
one ⌘Z: those slices become your word - they post like any confirmed
time, and no automatic pass will move them again. There is deliberately
no confirm-the-whole-day: visits you haven't viewed stay queued
untouched, so reviewing part of the day and coming back later just works
(viewed marks last until the app quits). A visit andeye can't yet place
at all stays queued even when viewed - there is nothing on show to
confirm.

The assign bar's task buttons are sorted by how likely each task is for
the selected visits - every highlighted visit counts, whether it was
picked on its own or as part of a group - most likely first, and a button
that has a likelihood shows it as a percentage - hover to see how the
number was built. Time tracked to
the same task immediately before and after a visit raises that task's
likelihood: strongly when both sides match, less when only one does, fading
out as the gap to the neighbour grows. Only decided, tracked time counts
here - a *pending review* neighbour never changes a likelihood.

The same continuity idea runs live: while the clock is running on a task,
a window that could plausibly belong to it is read as a continuation -
the running task's likelihood gets the one-sided nudge above, so an
ambiguous moment mid-flow queues for review less often than the same
window opened cold. Definite evidence (a pin, a task page, a learned
rule) always beats the nudge, and a stopped clock carries none.

Can't place a batch at all? The assign bar's **Unknown** button
sweeps it to the built-in Unknown task instead of clearing it or guessing -
the time stays tracked with full detail, just off your review queue. It shows
up hatched grey on the timeline and in the donut so it's never mistaken for a
real task, and you can reassign it from the timeline any time you do work out
what it was. If a later rule makes andeye confident about it on its own, it
reclaims itself back out of Unknown automatically.

Saving a rule shows a brief "who → task" notice with an Undo, and the first
time a learned rule goes on to fire for real, you're told once more, so a
decision it makes on your behalf is never silent. Both notices sit in the
popover, auto-dismiss on their own, and are never a system notification.

Every learned + pinned rule lives in **Settings ▸ Email → task
matching ▸ Context rules…** - an **Email** segment and a **Sites** segment,
each listed with its provenance. Click a row for its full detail; forget it
there, or forget a whole task's rules at once with its group's **Forget
all** button - either way, one undo (⌘Z) restores everything that click
removed. **Copy rules** puts the current segment's rules on the clipboard
as plain text.

A third **Corrections** segment is the audit trail of everything Time&I
has been taught: every pick, reassign, review assign and forget, with when
it happened, which gesture taught it, and on which window. When the
Evidence Card says a task was "remembered from a past correction" or
chosen on learned associations, the card also names that exact correction.

### Site rules: whole sites, and the pages inside them

On the web beyond email, andeye reads certain sites' pages into named
fields, so one correction can cover exactly the right slice of a site.
Built-in recipes understand:

- **GitHub** - owner, repository, section (issues, pulls, actions...) and
  the open issue/PR title. "Everything in the acme-web repo → task X" is one
  Remember at the repository grain.
- **Google Docs / Drive** - document type, the document itself, and its
  title. A document rule keys on the document's stable identity, so it
  survives a rename.
- **Xero** - the organisation, the app section (invoicing, bank,
  contacts...) and the page title. One Remember per organisation maps each
  set of books to its own task.

Every field is parsed from the page's address and window title - the same
things andeye already watches - so recipes add names and structure, never
new collection. A field a page doesn't show says "not captured" in the
Evidence Card, and the card's grain ladder lets you Remember at any field
(**Always 📌** pins it), exactly like the email ladder.

On sites without a recipe the ladder still offers the site itself: Remember
on the site row teaches "this whole site → task" in one tap, revisable and
forgettable like any learned rule; Always on the site row is the classic
100% pin.

The ledger's Sites segment carries a **Recipes** strip - one checkbox per
recipe. Turning a recipe off stops it reading anything; rules you taught
under it stay listed (greyed, dormant) until you turn it back on or forget
them. To see exactly what the recipes make of the page you're on, use
**Settings ▸ Diagnostics ▸ What recipes see here**.

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

One window shows your time two ways - a **timeline** and a **donut** - and you
flip between them in place. The Donut button in the popover opens it on the
timeline, the donut, or whichever you viewed last, per a Setting. Like every Time&I
window, it appears over full-screen apps and settles onto whichever desktop
you're working on.

### Switching views

There is no separate switcher button: the cross-previews are the navigation.

- In the **timeline**, the top-right mini-donut is today's breakdown. **Click
  it** to flip this window to the donut.
- In the **donut**, the "from HH:MM" strip is the current block's timeline. **Click
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
  The live (running) slice has no Billable menu of its own - mark it once it
  ends, or set the task's or project's billable flag directly and the live
  entry inherits it.
- **Allocate a stretch**: shift-drag (or shift-click, then shift-click again to
  extend) selects a time range, shown as a translucent band with its start and
  end - it isn't bound to any slice's edges, so it can cut straight through
  the middle of one. A small bar then offers **Allocate…** (pick a task) or
  **Unknown**; a slice only partly inside the range is split at its edge, the
  rest stays as it was. Esc or clicking empty space clears the selection.
- **Detail strip**: the windows inside the selected slice, with the "why" panel
  described above. Move windows to another task to split/reassign and teach the
  learner.

### Donut view

- **Period** (Today ⌘1 / Week ⌘2 / Last 7 days ⌘3 / Month ⌘4), with an
  "OpenProject only" filter (⌘⇧O) and a show/hide calendar (⌘⇧C).
- Projects in the inner ring, tasks in the outer. Hover to highlight,
  click to pin a selection; reassign time to another task from the bar.
- **Colours**: each project gets its own hue, and its tasks distinct shades
  around it - picked to stay tellable-apart (including under colour-blind
  vision) and never reshuffled: once a task has shown its colour, it keeps
  it. **Click any legend swatch** to choose your own colour for that project
  or task (Reset to automatic hands the choice back); your pick always wins,
  and a recoloured project guides the shades its future tasks pick up. The
  timeline's slice editor and a local task's Settings row offer the same
  picker.
- **Billable flags**: right-click a project or task to mark it billable or
  non-billable (tasks can also inherit from their project); billable rows
  carry a "billable" label in the legend. Marking a project billable warns
  you about already-tracked hours that will NOT be invoiced (flips apply to
  new time only) and leaves manually-set tasks as they were.

## Settings

Settings (⌘,) is organised into categories - a sidebar on the left, the
selected category's controls on the right: Tracking, Behaviour, Menu bar,
Colours, Local tasks, Connections, Currency, Email & Calendar, Maintenance,
Diagnostics, About. Press **⌘F** and type to find any setting by its label
or a related word ("color", "xero", "csv" all work); pick a result to jump
to its category. Every slider and stepper pairs with a typeable number box
bound to the same value, so you can enter a figure directly.

Colours: **Re-derive all automatic colours** rebuilds the whole automatic
palette cohesively (every project a distinct anchor, its tasks shading
around it - and around YOUR colour where you've picked one for a project);
**palettes** save colours to a JSON file and load them back - a full
palette captures the complete look, task names included, while a generic
palette is just the colours and loading one re-derives the automatic
colours around it; **Manually picked colours** lists every hand-picked
colour with an inline editor, per-row revert and a revert-all. A project's swatch popover
in the Time Donut legend also offers **Shade tasks around this**.

- **Auto-push to your connected app** - the one certainty threshold: sessions
  at least this certain post by themselves; everything below queues for your
  review. Push the slider past 100% to never auto-push and review everything.
- **Comments** - auto-comment time entries (the apps/docs used), and whether
  a typed note goes to the time entry, the task's feed, or both.
- **Menu bar** - the low/high certainty colours, **Monochrome menu bar**
  (template-mono like macOS's own items — no colour at all; for one fixed
  colour of your own, set both certainty colours to it), a certainty %,
  **Draw in certainty** (the mark strokes in proportion to certainty, eye
  first), and how many letters of the task name show after the time.
- **Popover default mode** - "Reassign" (default) or "Switch to".
- **Donut button opens** - Timeline / Last viewed / Donut.
- **Switch Buffer** and grace windows, idle and sleep handling.
- **Review queue floor** - a window only asks for review once its uncertain
  slices total this many seconds (default 60; it bottoms out at the Switch
  Buffer, where every uncertain slice asks). Briefer visits stay tracked
  and follow the Auto-push rule - they just never ask.
- **System notifications**, **lock the Mac when you continue work away**
  (the popover's walk figure, ⌘⇧L), **track leisure to local tasks**.
- **Hide banners while presenting** - while your mic is live or a display is
  mirrored, banners that would name a task or contact stay hidden, so
  nothing about your work pops up on a shared screen (on by default).
- **Idle backfill** - opt-in: when you return from an idle gap, offer to
  claim the gap for the task you were on (off by default; hours stepper caps
  how far back it offers).
- **Local tasks** - personal tasks (e.g. "Chess") you can track against,
  private to this Mac and never sent to a backend. Each row has a colour
  swatch, a name, and an optional project (blank means Personal, shown
  greyed); an Add row creates the next one and the trash deletes. Renaming
  keeps a task's history and colour.
- **Licence** - leads the Connections category, since it is what unlocks
  connectors; the app is complete without one. Paste a key (`ANDEYE1.`
  followed by two dot-separated blocks) and Apply: the tier (Plus / Pro /
  Premium / Enterprise), who it is licensed to, and the renewal date appear
  - lifetime keys show "lifetime". If the key can't be used, the reason
  appears in red below the field.
- **Connectors** - grouped Standard / Pro / Premium. Each connector's
  plumbing (instance URL, API key, connect, default activity) folds behind
  a disclosure whose heading shows the at-a-glance state ("OpenProject -
  143 tasks · your name"); it opens itself only while unconnected. Xero
  sits under Pro connectors, greyed with an upgrade link until your licence
  covers it.
- **Posting health** - appears under its connector only when something needs
  you: a count of entries stuck after repeated failures (with a one-click
  Retry) and a count of entries that disagree with your journal and can't be
  fixed automatically (usually because they're locked into an invoice), plus
  a "review them on the timeline" link when posted entries look mis-filed
  under today's rules. Ordinary edits and deletions of already-posted time
  propagate to the backend on their own within a minute or two.
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
  of heavy tracking; nobody gets pushed into a paid iCloud tier by Time&I.
- **Consolidate old history** - collapses slices older than a number of years
  you choose into daily totals. Totals and invoicing history survive exactly
  - only the minute-by-minute detail goes.
- **Hard cap - strongly discouraged** - deletes your oldest raw slices,
  double-confirmed, until the synced journal is back under a size you pick.
  ⌘Z brings them back until you quit the app - after that they're gone for
  good. It's for a genuine iCloud-quota emergency only, since the synced
  journal is normally tiny (see iCloud footprint above).
- **Email → task matching** - your own addresses/domains (comma-separated),
  so andeye never mistakes you for the other party when a message's
  correspondent decides the task. When a message matches several rules, the
  most specific wins: mail system, then domain, then correspondent, then
  subject. See Auto-tracking and attribution above for the rules themselves.
- **Calendar** - off by default; turning it on asks macOS for read-only
  calendar access once and reveals the rest of the section: the pre-meeting
  pulse and its lead time (1-15 minutes), the flash at meeting start, which
  calendars to ignore (comma-separated names - birthdays and subscribed
  holiday calendars are already excluded), and how far back the Review
  queue looks for a matching past event.
- **Billing** - the currency symbol (blank = your locale's own), a
  **Billable items** list of everything currently flagged billable, and
  (with a finance backend) the billing mappings. Projects and tasks
  default to non-billable - flag them in the Time Donut legend
  (right-click a project or task).

## Data, sync and safety

- Your time is journalled to a local SQLite database; that is the source of
  truth. Sessions at or above the Auto-push threshold you set post to your
  OpenProject automatically; everything below queues for your review.
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
- **⌘Z** - undo, as many times as you like: task switches, timeline edits,
  review sweeps, pins and learned rules, colours, deletes - each press steps
  one action back. The history lasts until you quit Time&I.

### Popover

A £ glyph after a task name (in the pick list, and after the running task in
the header) means its time is billable - resolved from the task's own
setting, or its project's.

- **⌘T** - flip the list between Switch-to and Reassign.
- **⌘P** - pin the current window/site (or, when pinned, open the pin editor).
- **⌘E** - open the Evidence Card (why this was tracked here, un-learn, fix).
- **⌘.** - stop tracking. **⌘R** - resume the last task.
- **⌘Z** - back to the previous task (same as the quiet ← button).
- **↵** in the filter - pick the top task in the list.
- **⌘↵** - claim the "you were away" idle gap as work.
- **⌘Y** - open the Time window. **⌘U** - open the Review queue.
- **⌘,** - Settings. **⌘Q** - quit Time&I.

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

- **⌘\\** - flip between the timeline and the donut.
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

### Time window - donut

- **⌘1 / ⌘2 / ⌘3 / ⌘4** - period Today / Week / Last 7 days / Month.
- **⌘⇧O** - toggle "OpenProject only". **⌘⇧C** - show / hide the calendar.
- **⌘[ / ⌘]** - previous / next month in the calendar.
- In the calendar: click a day to snap the period's width onto it; drag, or
  shift-click, to select an arbitrary span.

### Review queue

- Selection works like the Finder: **click** - select a visit (a row's
  header, or its left edge when open, selects its whole group); **⌘-click**
  - add or remove a row; **⇧-click** - select everything between the last
  row clicked and here, groups and single visits alike.
- **⌘D** or **⌫** - **Clear** the selection: drop it from the queue,
  nothing added to timesheets, nothing learned.
- **⌘E** - expand or collapse every stack and slice detail.
- **⌘[ / ⌘]** (or **← / →** while the list has focus) - walk the day's
  visits in either direction; each visit you land on opens and is marked
  viewed. **Confirm viewed** then confirms exactly the marked visits.
- **↵** in the task filter - assign the selection to the top task.
- **⌘⇧C** - copy the AI prompt. **⌘↵** - apply a pasted AI response.

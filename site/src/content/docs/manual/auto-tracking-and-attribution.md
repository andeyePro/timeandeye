---
title: Auto-tracking and attribution
description: How Time&i decides which task your time belongs to, and how to see why.
---

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

Turn on **Calendar** in [Settings](/manual/settings/) and a meeting that's
live right now nudges that slot in the ranking - never enough to beat a pin,
a URL match or a learned rule, just enough to break a tie among your
ordinary tasks. The pick list marks the matching task with a small clock; if
you're tracking something else during a meeting, the popover offers a
one-line "Calendar: <meeting> - Switch". The menu-bar mark also alerts you
around meetings: it pulses gently through the last few minutes before an
event starts (five by default - pick the lead time in Settings), then
flashes hard the moment the event begins before settling back to normal.
Both alerts can be switched off individually; a meeting already underway
when andeye starts never flashes after the fact, tentative invites pulse
but never flash, and all-day events never alert. The same matching runs
over your calendar history for the Review queue, so an old row that
overlaps a past meeting gets a one-click assign hint too. Corrections teach
it a rule the same way email does, and nothing calendar-derived ever leaves
your Mac.

## Context rules: see why, un-learn in one click

In the popover, the certainty line grows a "why?" suffix whenever a signal is
tracking (**⌘E**, or click it) - it expands the Evidence Card in place. In the
[Time window](/manual/time-window/)'s timeline, click a slice then a window in
its detail strip to see the same card full-size.

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
bar: queued rows keep the correspondents and subject captured while their
time accrued, so assigning a batch of low-certainty windows to one task
offers the identical Remember - at the correspondent, domain or subject
grain when every row in the batch shares one email context, or at the
mail-system grain when the batch only shares the mail system. Either place,
when that context has more than one
correspondent, checking the correspondent row expands it into a checkbox per
address, so you choose exactly who the rule should cover, not just the first
one andeye saw.

The queue only asks about moments worth a decision: a visit appears once
its slice is at least a minute long (tunable in Settings, "Review queue
floor"). Briefer glances stay tracked and journalled as normal - they just
never queue, however often they repeat - because a moment too brief to
switch tracking is never worth naming.

Clearing a backlog? Sort the queue from the control at the top - newest,
oldest, longest or shortest - then click a row and shift-click another to
select everything between them (⌘-click adds or removes single rows). One
press of **Do not track**, **Unknown** or a task then clears the whole
range, and one ⌘Z brings it all back.

Can't place a batch at all? The assign bar's **Unknown** button
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

Every learned + pinned email rule lives in
[Settings](/manual/settings/) ▸ Email → task matching ▸ Context rules…,
listed with its provenance. Click a row for its full detail; forget it there,
or forget a whole task's rules at once with its group's **Forget all** button -
either way, one undo (⌘Z) restores everything that click removed. **Copy
rules** puts the lot on the clipboard as plain text.

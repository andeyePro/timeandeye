---
title: Settings
description: The Settings window's categories - the auto-push threshold, behaviour, menu bar, colours, local tasks, connections, currency, email and calendar matching, maintenance - and the ⌘F search that finds any setting.
---

Settings (⌘,) is organised into categories: a sidebar on the left, the
selected category's controls on the right. Press **⌘F** (or click the search
field above the sidebar) and type to find any setting by its label or a
related word - "color", "xero" and "csv" all work; pick a result to jump to
its category. Every slider and stepper pairs with a typeable number box
bound to the same value, so you can enter a figure directly.

### Tracking

- **Auto-push to your connected app** - the one certainty threshold:
  sessions at least this certain post by themselves; everything below
  queues for your review. Push the slider past 100% to never auto-push and
  review everything.
- **Review queue floor** - a visit only asks for review once its slice is
  at least this many seconds long (default 60; it bottoms out at the Switch
  Buffer, where every uncertain slice asks). Briefer visits stay tracked
  and follow the Auto-push rule - they just never ask, however often they
  repeat.
- **When later evidence contradicts past entries** - update them
  automatically, leave them alone, or queue them for your review. Entries
  you assigned or pinned yourself are never touched in any mode; entries
  already posted are only ever flagged on the timeline.
- **Comments** - auto-comment time entries (the apps/docs used), and whether
  a typed note goes to the time entry, the task's feed, or both.

### Behaviour

- **Switch Buffer** and grace windows, idle and sleep handling.
- **Popover default mode** - "Reassign" (default) or "Switch to".
- **Donut button opens** - Timeline / Last viewed / Donut.
- **System notifications**, **lock the Mac when you continue work away**
  (the popover's walk figure, ⌘⇧L), **track leisure to local tasks**.
- **Hide banners while presenting** - while your mic is live or a display is
  mirrored, banners that would name a task or contact stay hidden, so
  nothing about your work pops up on a shared screen (on by default).
- **Idle backfill** - opt-in: when you return from an idle gap, offer to
  claim the gap for the task you were on (off by default; an hours stepper
  caps how far back it offers).

### Menu bar

- The low- and high-certainty colours, the certainty percentage, and how many
  letters of the tracked task's name show after the time.
- **Draw in certainty** - the &I mark strokes in proportion to certainty:
  just the eye when Time&I is unsure, the whole mark when it's certain.
- **Monochrome menu bar** - the whole item renders template-mono, tinted by
  macOS like its own status items; colour signalling is off while this is on.

### Colours

- **Re-derive all automatic colours** - rebuilds the whole automatic palette
  cohesively: every project gets a distinct anchor colour and its tasks shade
  around it - and around YOUR colour where you've picked one for a project.
  Colours you picked yourself are untouched. Edit any single colour from the
  Time Donut legend (click its swatch) or the timeline editor; a project's
  swatch popover also offers **Shade tasks around this**.
- **Palettes** - save colours to a JSON file and load them back. **Save
  palette** captures the complete current look (your picks plus the
  automatic assignments, task names included); loading it restores that
  look exactly. **Save generic palette** keeps just the colours, no names -
  loading one re-derives the automatic colours around it, so a favourite
  scheme can colour any set of tasks, and your own picks stay. **Load
  palette** reads either form; one undo restores what was there.
- **Manually picked colours** - every hand-picked colour in one collapsed
  list, each with an inline editor and a revert to automatic, plus a
  revert-all.

### Local tasks

- Personal tasks (e.g. "Chess") you can track against, private to this Mac
  and never sent to a backend. Each row has a colour swatch, a name, and an
  optional project (blank means Personal, shown greyed); an Add row creates
  the next one and the trash deletes. Renaming keeps a task's history and
  colour. The non-work catch-all task lives here too.

### Connections

- **Licence** - leads the category, since it is what unlocks connectors;
  the app is complete without one. Paste a key (`ANDEYE1.` followed by two
  dot-separated blocks) and Apply: the tier (Plus / Pro / Premium /
  Enterprise), who it is licensed to, and the renewal date appear -
  lifetime keys show "lifetime". If the key can't be used, the reason
  appears in red below the field.
- **Connectors** - grouped Standard / Pro / Premium. Each connector's
  plumbing (instance URL, API key, connect, default activity) folds behind
  a disclosure whose heading shows the at-a-glance state ("OpenProject -
  143 tasks · your name"); it opens itself only while unconnected. Xero
  sits under Pro connectors, greyed with an upgrade link until your licence
  covers it.
- **Posting health** - appears under its connector only when something
  needs you: a count of entries stuck after repeated failures (with a
  one-click Retry) and a count of entries that disagree with your journal
  and can't be fixed automatically (usually because they're locked into an
  invoice), plus a "review them on the timeline" link when posted entries
  look mis-filed under today's rules. Ordinary edits and deletions of
  already-posted time propagate to the backend on their own within a
  minute or two.

### Currency

- **Currency symbol** - shown wherever billable totals render; leave blank
  for your locale's own symbol. Projects default to non-billable - opt them
  in from the Time Donut legend (right-click a project or task).
- **Billing mappings** - with a finance backend connected, each billable
  project picks the backend task its time bills to.

### Email & Calendar

- **Email → task matching** - your own addresses/domains (comma-separated),
  so andeye never mistakes you for the other party when a message's
  correspondent decides the task. When a message matches several rules, the
  most specific wins: mail system, then domain, then correspondent, then
  subject. See
  [Auto-tracking and attribution](/manual/auto-tracking-and-attribution/) for
  the rules themselves.
- **Calendar** - off by default; turning it on asks macOS for read-only
  calendar access once and reveals the rest of the section: the pre-meeting
  pulse and its lead time (1-15 minutes), the flash at meeting start, which
  calendars to ignore (comma-separated names - birthdays and subscribed
  holiday calendars are already excluded), and how far back the Review
  queue looks for a matching past event.

### Maintenance

- **Duplicate reconcile** - scans for OpenProject time entries logged twice
  against the same task and minute. Click a match to see every difference
  between its entries, then Apply: the richest entry survives (the others'
  comments fold into it), the rest are deleted, and your journal re-points to
  the survivor - confirm each. Each entry's ↗ opens that task's time-entries
  report in OpenProject, so you can check anything not shown here (custom
  fields, say) before deleting.
- **Export timesheet** - copies a period's tracked time to the clipboard as
  CSV or Markdown, with or without a connected backend.
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

### About

- **Build details** - the exact version line to copy into a bug report.

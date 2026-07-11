---
title: Settings
description: The Settings window's categories - tracking thresholds, behaviour, menu bar, colours, local tasks, connections, billing, email and calendar matching, maintenance - and the ⌘F search that finds any setting.
---

Settings (⌘,) is organised into categories: a sidebar on the left, the
selected category's controls on the right. Press **⌘F** (or click the search
field above the sidebar) and type to find any setting by its label or a
related word - "color", "xero" and "csv" all work; pick a result to jump to
its category.

### Tracking

- **Auto-push and review thresholds** - how certain Time&I must be before a
  session posts by itself, and below what certainty it queues for review.
- **Review queue floor** - a visit only asks for review once its slice is
  at least this many seconds long (default 60; 0 shows everything). Briefer
  glances stay tracked - they just never queue, however often they repeat.
- **Comments** - whether a note goes to the time entry, the task's feed, or both.

### Behaviour

- **Switch Buffer** and grace windows, idle and sleep handling.
- **Popover default mode** - "Change to" (default) or "Switch to".
- **Time button opens** - Timeline / Last viewed / Pie chart.
- **System notifications**, **lock on leave**, **track leisure to local tasks**.
- **Quiet while presenting** - while your mic is live or a display is
  mirrored, banners that would name a task or contact stay hidden, so
  nothing about your work pops up on a shared screen (on by default).
- **Idle backfill** - opt-in: when you return from an idle gap, offer to
  claim the gap for the task you were on (off by default; an hours stepper
  caps how far back it offers).

### Menu bar

- The low- and high-certainty colours, the certainty percentage, and how many
  letters of the tracked task's name show after the time.

### Colours

- **Re-derive all automatic colours** - rebuilds the whole automatic palette
  cohesively: every project gets a distinct anchor colour and its tasks shade
  around it. Colours you picked yourself are untouched, and ⌘Z restores the
  previous palette. Edit any single colour from the Time Spent legend (click
  its swatch) or the timeline editor.
- **Colour sets** - save the complete current look (your picks plus the
  automatic assignments) to a JSON file, and load one back later - loading
  replaces everything and is one ⌘Z to undo.

### Local tasks

- Personal non-OP tasks (e.g. "Chess") you can track against, each with its
  own colour, plus the non-work catch-all task.

### Connections

- **OpenProject** - base URL and API key.
- **Posting health** - appears only when something needs you: per backend, a
  count of entries stuck after repeated failures (with a one-click Retry) and
  a count of entries that disagree with your journal and can't be fixed
  automatically (usually because they're locked into an invoice). Ordinary
  edits and deletions of already-posted time propagate to the backend on
  their own within a minute or two.

### Billing

- **Currency symbol** - shown wherever billable totals render; leave blank
  for your locale's own symbol.
- **Billing mappings** - with a finance backend connected, each billable
  project picks the backend task its time bills to.

### Email & Calendar

- **Email → task matching** - your own addresses/domains (comma-separated),
  so andeye never mistakes you for the other party when a message's
  correspondent decides the task; see
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

- **Licence** - the app is complete without one; a licence only adds paid
  connectors. Paste a key (`ANDEYE1.` followed by two dot-separated blocks)
  and Apply: the tier (Plus / Pro / Premium / Enterprise), who it is licensed
  to, and the renewal date appear - lifetime keys show "lifetime". If the key
  can't be used, the reason appears in red below the field.
- **Build details** - the exact version line to copy into a bug report.

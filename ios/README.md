# andeye for iOS

The second screen + manual tracker (iOS cannot observe other apps — the
automatic attribution stays a Mac superpower). Two-tap tracking: open the
app, tap a task. Reuses the shared engine wholesale: `timeandeyeCore` (models,
ranking, backends, export) and `timeandeyeStore` (the SQLite journal replica,
CloudKit transport) — the OpenProject backend works fully over the network
from the phone, and CloudKit journal sync switches on with the entitled
App Store build.

## Build (needs full Xcode — the CLT-only Mac loop can't build iOS)

```bash
brew install xcodegen          # once
cd ios && xcodegen             # generates andeye.xcodeproj from project.yml
open andeye.xcodeproj          # select your team, build to a device/simulator
```

STATUS: builds for the iOS Simulator (xcodebuild on the build Mac, Xcode
26.6) and has had a first on-device test pass. CloudKit entitlements are
deliberately absent until App Store distribution is configured — do
not add the iCloud capability before then.

## What's in / out (v1)

- IN: two-tap manual tracking with live clock and a compact stop control
  (tapping a task switches; tapping the tracked task is a no-op; long-press
  a row to re-label the running timer without restarting it); crash-safe
  running slice (same checkpoint pattern as the Mac); ranked recent-first
  task list with fuzzy filter; local task creation; a LIVE mini-pie in the
  toolbar opening the Time page — donut of the period's time by project
  (tap a wedge for its task ring; Today/Week) plus a read-only timeline of
  the day's slices; OpenProject connect (URL + API key, same file-based
  key store); auto-push of finished slices; today's total; 7-day CSV
  timesheet via the hamburger menu's share.
- OUT (named next steps): CloudKit journal sync (engine done + checked in
  the main package — needs entitlements), Live Activity lock-screen timer,
  widgets, Watch, calendar/location context signals, Pro backends (Xero —
  ships via the Pro app flavour).

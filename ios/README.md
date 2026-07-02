# andeye for iOS

The second screen + manual tracker (iOS cannot observe other apps — the
automatic attribution stays a Mac superpower). Two-tap tracking: open the
app, tap a task. Reuses the shared engine wholesale: `AmbitickCore` (models,
ranking, backends, export) and `AmbitickStore` (the SQLite journal replica,
CloudKit transport) — the OpenProject backend works fully over the network
from the phone, and CloudKit journal sync switches on with the entitled
App Store build.

## Build (needs full Xcode — the CLT-only Mac loop can't build iOS)

```bash
brew install xcodegen          # once
cd ios && xcodegen             # generates andeye.xcodeproj from project.yml
open andeye.xcodeproj          # select your team, build to a device/simulator
```

STATUS: source-complete and desk-checked; not yet compiled (no iOS SDK in
the build loop). Expect a first-build fixup pass in Xcode. CloudKit
entitlements are deliberately absent until the Apple organisation conversion
completes — do not add the iCloud capability before then (assets would mint
under the personal team).

## What's in / out (v1)

- IN: two-tap manual tracking with live clock; crash-safe running slice
  (same checkpoint pattern as the Mac); ranked recent-first task list with
  fuzzy filter; local task creation; OpenProject connect (URL + API key,
  same file-based key store); auto-push of finished slices; today's total;
  7-day CSV timesheet via the share sheet.
- OUT (named next steps): CloudKit journal sync (engine done + checked in
  the main package — needs entitlements), Live Activity lock-screen timer,
  widgets, Watch, calendar/location context signals, Pro backends (Xero —
  ships via the Pro app flavour).

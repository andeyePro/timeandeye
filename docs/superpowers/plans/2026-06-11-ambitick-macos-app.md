# Ambitick macOS App Implementation Plan (Plan 2)

> Historical record: "Ambitick" was the working name — the app is now **andeyeTT** (user-facing brand "andeye"). Module/file names below are the pre-rename ones (Ambitick* → AndeyeTT*).

> Executed inline overnight 2026-06-11 by the same agent that wrote it; compact
> by design — full architectural context lives in the spec
> (`docs/superpowers/specs/2026-06-10-ambitick-design.md`) and Plan 1.

**Goal:** A runnable `Ambitick.app` menu-bar app wiring AmbitickCore to real
macOS sensors, SQLite persistence, Keychain, notifications, and SwiftUI UI.

**Verification reality:** the build user has no GUI session, so UI code is
verified by compilation + view-model checks only; interactive smoke testing is
Martin's morning task (checklist in README).

## Targets (added to Package.swift)

- **AmbitickMac** (library, macOS-only): everything testable-but-platform-bound
  - `SQLiteJournalStore` — raw `import SQLite3` (no GRDB dependency; thinner
    than the spec's GRDB suggestion, zero third-party deps — deviation noted)
  - `KeychainStore` — OP API key via Security framework
  - `Sensors/` — `FocusSensor` (NSWorkspace + AX window title + Chrome tab via
    NSAppleScript, 2 s poll), `IdleMonitor` (CGEventSource), `SleepMonitor`
    (NSWorkspace notifications), `MicMonitor` (CoreAudio
    kAudioDevicePropertyDeviceIsRunningSomewhere), `pmset` display-sleep reader
  - `AppController` — wires sensors → SessionTracker → journal → SyncEngine;
    owns task-cache refresh (60 s), menu-bar title cadence (1 Hz first minute
    after a change, then per-minute), prompt → notification routing
- **AmbitickApp** (executable): SwiftUI `MenuBarExtra` (.window style) popover
  — current task + certainty (+ optional %), stop, pick list (recent+likely),
  review window (multi-select assign), settings (incl. colours, threshold
  slider to "never", leisure toggle, API key field)
- **AmbitickCoreChecks** gains: SQLite conformance run (same
  `journalStoreConformanceChecks` against a temp-file SQLiteJournalStore) and
  AppController cadence/view-model checks.

## Task order

1. SQLiteJournalStore + conformance checks green
2. KeychainStore (build-verified; Keychain calls smoke-tested in the morning)
3. Sensors (build-verified; AX/Automation paths need permissions = morning)
4. AppController + cadence logic with checks
5. SwiftUI app target, bundle script (`scripts/make-app.sh`: build → .app
   skeleton with LSUIElement Info.plist → ad-hoc codesign)
6. README setup instructions + morning smoke checklist
7. Full check suite + `swift build` of everything green on the Mac → push

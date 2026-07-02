# andeye

(The original working name was **Ambitick** — it survives in the repo URL
and module names.)

Automatic time tracking against your project-management tool's tasks. A macOS
menu-bar app that watches which window, app or browser tab is active and
attributes the time to the most likely task, learning from your confirmations
so prompts reduce over time. Local-first: a SQLite journal on your Mac is the
source of truth; nothing leaves the machine except pushes to your own backend
(and the optional copy-paste AI assist you trigger yourself).

Backends plug in behind a seam (`TaskBackend`): **OpenProject** is fully
supported today, **Xero** is next, and **standalone** (no backend at all)
works now — local tasks, full timeline/pie, CSV/Markdown timesheet export
from Settings ▸ Maintenance.

Day-to-day usage: **[MANUAL.md](MANUAL.md)**. Spec:
`docs/superpowers/specs/2026-06-10-ambitick-design.md`. Status: v0.1 pre-alpha.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Ambitick/Ambitick.git
cd Ambitick
./scripts/make-app.sh          # builds release binary, wraps it as andeye.app
```

Run the checks (no XCTest needed – plain executable):

```bash
swift run AmbitickCoreChecks   # expect: TOTAL: N passed, 0 failed
```

## First-run setup

1. **Launch**: right-click `andeye.app` → Open (it is ad-hoc signed, not
   notarized). A grey dot + `–` appears in the menu bar.
2. **Accessibility** (window titles): System Settings → Privacy & Security →
   Accessibility → enable andeye. The app prompts on first launch.
3. **Automation → browser** (tab URLs): the first time Chrome/Opera/Brave is
   frontmost, macOS asks "andeye wants to control Google Chrome" → Allow.
4. **Connect OpenProject**: menu-bar dot → Settings → enter your instance URL
   and an API key (OP: Account settings → Access tokens → API). The key goes
   to the macOS Keychain, the task list loads, and the instance's activity
   list populates the default-activity picker.
5. **Tune** (optional): auto-push certainty threshold (slider past 100% =
   never auto-push, review everything), menu-bar colours (identical colours
   disable the signalling), certainty %, leisure tracking.

## Nomenclature

andeye records time in a small hierarchy — these are the words used in the
UI, this README, and the code:

- **Slice** — one contiguous stretch of time tracked to a single task. A slice
  becomes one OpenProject **time entry**. (Synonyms you might think of —
  "task track", "time track" — all mean *slice*.)
- **Block** — a run of consecutive slices separated by gaps of no more than
  one hour. The timeline opens framed on the latest block.
- **Window** — the within-slice detail: which application/window was actually
  active for each part of a slice, or that the time was drawn/edited by the
  user, or entered via a secondary app (e.g. a future iOS companion). Windows
  are shown in the strip beneath a selected slice and can be peeled out to a
  different task.

A brief hop to another window (shorter than the **switch buffer**, Settings →
Behaviour, default 30 s) does *not* start a new slice — it stays a window
inside the current slice. The menu-bar clock always shows what *would* be
recorded if nothing else changed: it follows the window you're in instantly,
but if you return to the previous slice's window before the buffer elapses it
reverts, and that hop is kept as a window in the slice you came back to.

## The three views

- **Popover** (menu-bar dot): current task, per-task clock, certainty, note
  bubble (becomes the OP comment), stop/resume, filterable switch list.
- **Timeline** (popover → timeline icon): a horizontal bar of the day's
  slices, coloured per task, opening framed on the current block. Two-finger
  scroll pans, pinch zooms. Drag on empty space to draw a new slice (snaps to
  neighbours); click a gap to fill it; click a slice to edit it, then drag its
  edge handles (dragging over a neighbour eats into it). Edit
  task/start/end/duration/comment/colour or delete — Enter saves, Esc cancels;
  edits write back to OpenProject. Two same-task slices brought to butt up
  against each other merge losslessly. The live slice shows the task colour
  with a zig-zag end; its windows are in the strip below, where you can select
  windows and reassign them to another task (splitting the slice).
- **Time Spent** (popover → pie icon): donut of projects for a period
  (default today). Hover a wedge for the task ring, hover a task for the app
  ring; click pins; the legend drills the same way.

## Local (non-OpenProject) tasks

Settings → "Local tasks": create tasks like Chess or Family admin that are
tracked, timelined and charted exactly like work tasks but never leave the
machine. Mark one "leisure" and enable "Track leisure" to have confident
non-work time land there instead of stopping the clock.

## Morning smoke checklist (v0.1)

- [ ] App appears in menu bar; dot is grey while stopped
- [ ] Open an OP work-package page in Chrome → timer auto-starts (notification)
- [ ] Switch to a work window ≥ 30 s, click dot → click the task → association
      sticks (dot goes green-ish on return)
- [ ] Menu-bar time ticks every second for the first minute, then per-minute
- [ ] Click dot → Stop works; pick list shows recent + likely tasks
- [ ] Leave the Mac idle past your display-sleep time → timer stops, trimmed
      to last input; on return a resume prompt shows in the popover
- [ ] Review window: rows accumulate during uncertain time; multi-select +
      one-click assign works; "Copy AI prompt" fills the clipboard
- [ ] With API key set and threshold reachable: a confident session creates a
      time entry in OP (check the work package's spent time)

## Architecture

- `AmbitickCore` – platform-independent engine: attribution (task URL ≈ 100%,
  task-priming, learned associations, ranking priors), dominant-minute session
  resolution, journal protocol, the `TaskBackend` seam (OpenProject behind
  `OPBackend`; Xero next; standalone = no backend), sync, timesheet export,
  AI-assist, settings. No AppKit; the iOS companion (planned in this repo, as
  an `ios/` Xcode project) reuses it unchanged.
- `AmbitickMac` – SQLite journal (raw sqlite3, no deps), Keychain, sensors
  (NSWorkspace, Accessibility window titles, browser tabs via Apple Events,
  idle, sleep/wake, mic-in-use), app controller.
- `AmbitickApp` – SwiftUI `MenuBarExtra` popover, review window, settings.
- `AmbitickCoreChecks` – the test suite as a plain executable (no XCTest
  anywhere); CI runs it on macOS (the Mac layer imports AppKit/SQLite3, so
  Linux can't build the full suite).

## Known v0.1 limits

- Safari tab URLs not yet read (Chrome/Opera/Brave only).
- Calls answered on the iPhone are invisible (look like idle time).
- Onboarding is this README; in-app guided onboarding arrives with user 2.

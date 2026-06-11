# Ambitick

Automatic time tracking for OpenProject. A macOS menu-bar app that watches
which window, app or browser tab is active and attributes the time to the most
likely OpenProject work package ("task"), learning from your confirmations so
prompts reduce over time. Local-first: a SQLite journal on your Mac is the
source of truth; nothing leaves the machine except pushes to your own OP
instance (and the optional copy-paste AI assist you trigger yourself).

Spec: `docs/superpowers/specs/2026-06-10-ambitick-design.md`. Status: v0.1 pre-alpha.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Ambitick/Ambitick.git
cd Ambitick
./scripts/make-app.sh          # builds release binary, wraps it as Ambitick.app
```

Run the checks (no XCTest needed – plain executable):

```bash
swift run AmbitickCoreChecks   # expect: TOTAL: N passed, 0 failed
```

## First-run setup

1. **Launch**: right-click `Ambitick.app` → Open (it is ad-hoc signed, not
   notarized). A grey dot + `–` appears in the menu bar.
2. **Accessibility** (window titles): System Settings → Privacy & Security →
   Accessibility → enable Ambitick. The app prompts on first launch.
3. **Automation → browser** (tab URLs): the first time Chrome/Opera/Brave is
   frontmost, macOS asks "Ambitick wants to control Google Chrome" → Allow.
4. **Connect OpenProject**: menu-bar dot → Settings → enter your instance URL
   and an API key (OP: Account settings → Access tokens → API). The key goes
   to the macOS Keychain, the task list loads, and the instance's activity
   list populates the default-activity picker.
5. **Tune** (optional): auto-push certainty threshold (slider past 100% =
   never auto-push, review everything), menu-bar colours (identical colours
   disable the signalling), certainty %, leisure tracking.

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

- `AmbitickCore` – platform-independent engine: attribution (OP URL ≈ 100%,
  task-priming, learned associations, ranking priors), dominant-minute session
  resolution, journal protocol, OP client, sync, AI-assist, settings. No
  AppKit; the future iOS companion reuses it unchanged.
- `AmbitickMac` – SQLite journal (raw sqlite3, no deps), Keychain, sensors
  (NSWorkspace, Accessibility window titles, browser tabs via Apple Events,
  idle, sleep/wake, mic-in-use), app controller.
- `AmbitickApp` – SwiftUI `MenuBarExtra` popover, review window, settings.
- `AmbitickCoreChecks` – the test suite as a plain executable (the build
  environment has no XCTest); CI-friendly on Linux and macOS alike.

## Known v0.1 limits

- Safari tab URLs not yet read (Chrome/Opera/Brave only).
- Calls answered on the iPhone are invisible (look like idle time).
- Onboarding is this README; in-app guided onboarding arrives with user 2.

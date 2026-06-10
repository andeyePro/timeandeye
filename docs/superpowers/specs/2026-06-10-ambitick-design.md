# Ambitick v0.1 – design

Status: approved by Martin 2026-06-10 (this document is the written form of that approval, with his amendments folded in).

## What it is

Ambitick is a native macOS menu-bar app that tracks how time is spent without user effort. It watches the active window / application / browser tab and attributes time to the most relevant **task** (UI term; the OpenProject API layer calls them work packages). Guiding principle throughout: **minimal user effort – as few clicks/swipes as possible.**

v0.1 targets one user (Martin), one OpenProject instance, Chrome as the only deeply-integrated browser.

## Architecture

Swift Package with strict module boundaries, so the iOS companion can follow without rework:

- **AmbitickCore** – pure Swift, zero AppKit/UIKit. Task cache + ranking, attribution engine, learning store, session journal, OpenProject client, settings model. Fully unit-testable; tests runnable with `swift test` on Linux (CI/container) as well as macOS.
- **AmbitickSensors** – macOS-only. All observation behind a single `ActivitySource` protocol: frontmost app (NSWorkspace), focused window title (Accessibility/AXUIElement), Chrome active-tab URL (Apple Events), idle seconds (CGEventSource), sleep/wake (NSWorkspace notifications), microphone-in-use (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`).
- **Ambitick.app** – SwiftUI `MenuBarExtra` (`.window` style) menu-bar target plus a regular review window. Launch at login.

iOS companion (later, reuses Core untouched): predominantly manual tracking when away from the Mac. Two-click tracking – open app, tap task – with the most-likely tasks filling the screen sorted by probability. While tracking, the current task + its probability pin to the top, others below in decreasing probability; if space permits, a "likely next" section so it doubles as an extra-window companion beside the Mac. Hamburger menu for everything else (review queue, totals, manual timers, settings). iOS cannot observe other apps; sensing stays macOS-only forever.

## Task cache and ranking

Core maintains a full local list of the user's OP work packages, refreshed by API poll. Likelihood ranking combines:

- status prior, in configurable rank order (Martin's: Now > Next > Open > Closed)
- recency of last user-confirmed tracking
- learned associations (below)
- time-of-day prior

No separate "Closed but in active use" flag: recency keeps actively-tracked Closed tasks (e.g. Timesheets) ranked high while dormant Closed tasks decay. Closed tasks are never excluded from pick lists.

Ranking exists to make attribution fast and to populate every "pick a task" surface (popover switch list, review assign shortlist, iOS screen) with N most recent + M most likely.

## Attribution engine

Every focus change emits a signal: (app, window title, tab URL, timestamp). Scoring sources, strongest first:

1. **OP tab URL containing a task id** – ≈100% certainty; backbone of the learning loop.
2. **OP task-priming**: when the user opens a task in OP (active tab URL carrying the task id), that signals probable clock-start; the next window/tab to hold focus for more than X seconds (setting, default 30 s) becomes the candidate *working surface* for that task. Easy confirm: click the menu-bar icon, click the task, then return to the same window/tab for >X seconds. Once confirmed, the surface→task association is maintained as most-likely until the user uses that window/tab immediately following a *different* OP task page, or otherwise assigns a different task to that window/tab.
   - Time spent in OP itself on pages *without* a task id attributes to the most appropriate task in that project (by ranking); outside any project, to the user's general-purpose tasks (e.g. Planning or Timesheets) as appropriate.
3. **Learned associations** – per-task weights over (app, title tokens, URL host/path) built from past confirmations and corrections.
4. **Priors** – status/recency rank, time-of-day.

Within any one minute, the dominant task wins the whole minute. Output: **one time entry per continuous work session per task.**

Known surfaces (Martin's): four vibe sessions in Ghostty quarters (window titles already distinct – vibe sets the repo name as the Ghostty title; focused-window title is the discriminator), OP, Chrome (Gmail, Meet, Sheets, Docs), WhatsApp (mixed work/non-work), Obsidian, Excel, Word.

## States and certainty

- **Tracking, confident** → icon colour toward the "certain" end.
- **Tracking, uncertain** → keep attributing to the last certain task; coalesce the activity log (consecutive same app+title merged, minimum segment ~20 s) into a review queue, one row per coalesced window/tab change.
- **Non-work detected (confident)** → by default, auto-stop the timer. No "should I stop?" prompt – instead a clearly distinct stop-clock alert (visible + optional audible), different from the task-change alert. User option: track leisure instead – games/entertainment time attributes to **local-only tasks** that exist in Ambitick but are never pushed to OP.
- **Stopped** → grey icon.

Certainty is displayed as a **continuous colour gradient** between two user-selectable colours (default red→green; black/white allowed), with grey for stopped. Selecting two identical colours disables the signalling, so no separate toggle is needed; numeric % display is an opt-in toggle.

Task-switch and timer-stop moments raise a popup listing "Do not track" at the top, then the most likely tasks, for one-click selection, with a single-click/Esc postpone.

Task-change and stop-clock alerts are also delivered as system notifications with distinct (optional) sounds, so changes remain visible when the menu bar is hidden (fullscreen apps, auto-hidden menu bar).

## Menu bar UI

- Text: elapsed time on current timer. Refresh 1 Hz for the first minute after a task change (alerts the user to the switch), then once per minute.
- Optional % suffix (toggle).
- Click opens the popover: current task name + certainty, stop button, switch list (N recent + M most likely, single click), link to the review window.

## Review window

Regular window. Timeline list of coalesced low-certainty log rows. Click-and-drag, shift-click, ⌘-click and the usual macOS multi-selection idioms to group rows belonging to one task, then one-click assign from a most-likely shortlist (with "Do not track" at the top). Assignments feed the learning store.

## Idle, sleep, calls

- **Idle threshold** derived from the Mac's own display-sleep setting (read via `pmset -g`). When the threshold is hit (or the Mac sleeps), the tracker retro-trims the session to the last keyboard/mouse input. On resume/wake, ask: "work continued, or was the stop time correct?" TODO: user option for a shorter idle threshold.
- **Calls**: microphone-in-use is the call proxy, for calls taken on the Mac (FaceTime, Continuity, WhatsApp desktop, Meet). Mic active while focus is on a known work surface (e.g. a Meet tab) → keep tracking. Mic active otherwise → treat as call segment (uncertain). Mic released = end of call → postponable prompt: a list with "Do not track" at the top, then the most likely tasks. Caller identity is not available to apps. Calls answered on the iPhone are invisible to the Mac and will appear as idle. iPhone-side call detection: parked TODO.

## OpenProject sync

- Local SQLite journal (GRDB) is the source of truth. OP is a sync target, never the master of tracked time. (SQLite is the engine Apple's own stock apps and Core Data use; GRDB is a thin Swift layer over it, chosen over Core Data to keep Core pure and portable.)
- Local-only tasks (leisure tracking) live in the same journal and are excluded from push.
- Sessions at/above a **user-set certainty threshold** auto-push as OP time entries; below it they wait in the review queue. The threshold slider tops out at "never auto-push" (review everything).
- Time entries: one per work session. Comment auto-population is a setting: on → the comment summarises what was done (dominant apps/documents/pages); off → comments stay empty. Either way, editable in review before push. OP requires an Activity per entry → the app fetches the instance's activity list at setup; user confirms a default in settings (instance default pre-selected), with per-task learned override.
- Single OP instance; API key in the macOS Keychain.

## Learning

Every confirmation, correction, and non-work verdict updates association weights (lightweight frequency/Bayes-style scoring – instant, free, fully local). Goal stated in the brief: prompts and corrections reduce over time. No AI on the hot path.

## AI assist (cold start, on request only)

No API integration in v0.1. When the user requests it, the app generates a classification prompt (open task list + unmatched signals) and copies it to the clipboard; the user pastes it into the AI of their choice (Claude, local model, anything) and pastes the response back into the app. The app validates a strict JSON response format before ingesting. Nothing ever leaves the device except by this explicit user copy-paste.

## Privacy

All data local (SQLite journal + learning store). Outbound traffic: the user's own OP instance only. No telemetry.

## Distribution and setup

- Developer ID + notarization; Accessibility and Apple-Events permissions rule out sandboxing/Mac App Store for the Mac app. (iOS companion can be App Store – it senses nothing.)
- **README carries full user-1 setup instructions**: build/install, the three permission grants (Accessibility, Automation→Chrome; mic-state observation needs no permission), OP URL + API key entry, launch-at-login.
- Interactive onboarding UI: parked until user 2.

## Testing

- AmbitickCore: unit tests for ranking, attribution scoring, session coalescing, journal, OP client (mocked HTTP) – runnable on Linux and macOS.
- AmbitickSensors: thin, manually verified; protocol allows a scripted fake `ActivitySource` to drive end-to-end Core tests.
- App: manual smoke per release; verification by *using* the artifact (menu bar behaviour, popover, review flow).

## Parked TODOs

- Interactive onboarding flow (user 2)
- Safari, then Opera, then others
- User-set shorter idle threshold
- iPhone-side call detection
- WhatsApp work/non-work chat discrimination (learn from corrections)
- Other PM backends beyond OpenProject

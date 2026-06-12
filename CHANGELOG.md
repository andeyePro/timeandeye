# Changelog

## 2026-06-12

- [x] **Timeline, Time Spent, local tasks (the `timeline` branch)** - Full
  interactive timeline (viewport bar, block-framing, draw/gap-fill/edge-drag
  editing with snapping and neighbour-trim, OP write-back via stored entry
  ids, window-detail strip with connectors, live-slice start edit), Time
  Spent donut (project>task>app hover rings, pin, legend), local non-OP task
  system with Settings UI and leisure routing, per-task colours, span
  recording with 30-day retention, crash traps to the debug log, self-drawn
  notification banners, per-task banked clocks with flash-visit limbo.
  81 checks + live-OP integration green throughout.

## 2026-06-11

- [x] **Ambitick v0.1 pre-alpha (overnight build)** — Full first implementation
  from the approved spec, e6a62dd..HEAD. `AmbitickCore`: domain models, OP URL
  parsing, naive-Bayes learning store, status/recency/time-of-day ranking,
  attribution with OP task-priming and OP-host fallback, dominant-minute
  session resolution, journal protocol, OpenProject v3 client (1-based page
  pagination), threshold-gated sync, copy-paste AI assist, settings.
  `AmbitickMac`: raw-sqlite3 journal (passes the same conformance suite),
  Keychain key storage, sensors (frontmost app, AX window titles, Chrome/Opera/
  Brave tab URLs via Apple Events, idle, sleep/wake, mic-in-use), app
  controller with 1 Hz→per-minute menu cadence. `AmbitickApp`: SwiftUI
  MenuBarExtra popover, review window (multi-select assign), settings UI.
  `scripts/make-app.sh` wraps it as ad-hoc-signed `Ambitick.app` (LSUIElement).
  56 checks green via `swift run AmbitickCoreChecks` — a plain-executable
  harness because the build Mac has CLT only (no XCTest/Swift Testing).
  Verified on Mac over scoped SSH (`ambitick` standard user). UI smoke testing
  deliberately deferred to Martin (README checklist): no GUI session available
  to the build user.

## 2026-06-11 (day-2 fixes)

- [x] **Live-fire fixes + real-OP integration runner** — switch-grace buffer
  (brief window excursions merge; commits via input ticks), per-task clock,
  s/m/h+m menu format, persistent primed associations, weighted session
  certainty, optional activity, ISO-8601 startTime (verified stored by OP),
  stable signing identity (TCC grants survive rebuilds), legacy notification
  API (process-abort fix), auto-resume after idle, loud connection/push
  diagnostics, popover/review type-to-filter, AmbitickIntegration headless
  end-to-end against live OP as the Claude test account. 69 unit checks +
  INTEGRATION PASS.

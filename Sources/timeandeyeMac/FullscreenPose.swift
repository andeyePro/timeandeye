import Foundation

/// The pure Space/level decision behind the themed windows' float-over-
/// fullscreen behaviour (SpaceJoiningView in timeandeyeUI): given what the
/// screen looks like and where the window is in its open/settle lifecycle,
/// should it wear the fullscreen-capable pose — floating level +
/// canJoinAllSpaces, the one arrangement proven to overlay fullscreen apps
/// — or the plain desktop pose (normal level, current Space only)?
///
/// Extracted here, AppKit-free, so timeandeyeChecks (which does not link
/// timeandeyeUI) can pin the whole decision matrix. The view supplies the
/// AppKit facts (visibleFrame heuristic, isVisible, the popover flag, the
/// menu-bar preference) and applies the returned pose; every rule lives in
/// `decide`.
///
/// All times are MONOTONIC (ProcessInfo.systemUptime domain), never Date():
/// an NTP/clock jump must not stretch or kill the open grace.
package struct FullscreenPose {
    /// How long a freshly opened/reopened window holds the fullscreen pose
    /// unconditionally. Opening from the menu-bar popover REVEALS the menu
    /// bar, so the fullscreen-look heuristic reads false at exactly the
    /// open instant; by grace expiry the bar has re-hidden if the Space
    /// really is fullscreen.
    package static let graceSeconds: TimeInterval = 4
    /// How long the screen must look non-fullscreen CONTINUOUSLY —
    /// measured in time, not samples — before a floating window settles to
    /// the desktop pose. Time-based so render/apply bursts cannot spend
    /// the stickiness, and long enough (~5 s) that a pointer-at-top
    /// clock-glance over a real fullscreen app never evicts a window in
    /// use: the menu bar re-hides when the pointer leaves, resetting the
    /// run well before it completes.
    package static let settleSeconds: TimeInterval = 5

    package struct State: Equatable {
        /// Uptime deadline of the open/reopen grace.
        package var graceUntil: TimeInterval
        /// Uptime at which the current continuous run of demotion-eligible
        /// non-fullscreen samples began; nil = no run in progress.
        package var nonFullscreenSince: TimeInterval?
        /// Whether the window currently wears the fullscreen pose. This is
        /// the decision output as well as sticky input.
        package var floating: Bool

        /// A window always OPENS in the fullscreen pose (macOS decides the
        /// Space transition at show time, before any later sample could
        /// promote it) and only settles after the grace.
        package init(openedAt now: TimeInterval) {
            graceUntil = now + FullscreenPose.graceSeconds
            nonFullscreenSince = nil
            floating = true
        }

        /// A retained window re-shown (SwiftUI reopens the same NSWindow)
        /// restarts the grace, so a reopen never settles at normal level
        /// while the Space it landed on is still making up its mind.
        package mutating func restartGrace(at now: TimeInterval) {
            graceUntil = now + FullscreenPose.graceSeconds
            nonFullscreenSince = nil
        }
    }

    /// One sample. `looksFullscreen` is the menu-bar heuristic
    /// (visibleFrame reaches the screen top); `popoverOpen` is the app's
    /// own MenuBarExtra popover — which reveals the menu bar and blinds
    /// the heuristic for exactly as long as it is open; `menuBarAutoHides`
    /// is the System Settings auto-hide preference; `visible` is
    /// NSWindow.isVisible. Returns the new state; `.floating` on it is the
    /// pose to apply.
    package static func decide(now: TimeInterval,
                              looksFullscreen: Bool,
                              popoverOpen: Bool,
                              menuBarAutoHides: Bool,
                              visible: Bool,
                              state: State) -> State {
        var s = state
        // Menu-bar auto-hide (System Settings): visibleFrame reaches the
        // screen top on EVERY desktop, so the heuristic would read
        // permanent fullscreen and every themed window would float above
        // all apps and follow the user to every Space, forever. In that
        // mode the float-over-fullscreen behaviour is disabled wholesale —
        // windows behave plain-normal (and may be evicted when opened over
        // a real fullscreen app: the documented trade, better than
        // permanent squatting). A positive fullscreen detector could lift
        // this — see TODO.md.
        if menuBarAutoHides {
            s.floating = false
            s.nonFullscreenSince = nil
            return s
        }
        // Hidden retained window: keep MAINTAINING the fullscreen-capable
        // pose. AppKit/SwiftUI re-assert flags on hidden windows, so a
        // pose parked once on hide would not stick — and macOS decides the
        // Space at show time, before any post-show sample could repair it.
        // A maintained window reopens already wearing the right pose.
        if !visible {
            s.floating = true
            s.nonFullscreenSince = nil
            return s
        }
        // The screen looks fullscreen: promote immediately (a settled
        // desktop window floats again the moment its Space goes
        // fullscreen) and reset the demotion run.
        if looksFullscreen {
            s.floating = true
            s.nonFullscreenSince = nil
            return s
        }
        // Open/reopen grace: hold the fullscreen pose AND leave the
        // stickiness unspent — samples during the grace must not
        // pre-count, or the protection is already gone at grace expiry.
        if now < s.graceUntil {
            s.floating = true
            s.nonFullscreenSince = nil
            return s
        }
        // Our own popover is open: the menu-bar reveal it causes is why
        // the heuristic reads non-fullscreen right now, so HOLD — freeze
        // the run, never demote (covers a user holding the popover open
        // past the grace). A settled desktop window is NOT promoted by
        // this branch; it just stays put.
        if popoverOpen {
            s.nonFullscreenSince = nil
            return s
        }
        // A demotion-eligible non-fullscreen sample. Sticky settle: only a
        // CONTINUOUS settleSeconds run demotes, and repeated samples at
        // the same instant advance nothing.
        if s.floating {
            let since = s.nonFullscreenSince ?? now
            s.nonFullscreenSince = since
            if now - since >= settleSeconds {
                s.floating = false
                s.nonFullscreenSince = nil
            }
        } else {
            s.nonFullscreenSince = nil
        }
        return s
    }
}

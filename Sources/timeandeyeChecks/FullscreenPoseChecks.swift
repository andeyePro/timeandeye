import Foundation
import timeandeyeMac

func fullscreenPoseChecks(_ c: Checks) {
    // The whole float-over-fullscreen decision matrix, pinned without
    // AppKit: FullscreenPose.decide is the pure brain SpaceJoiningView
    // (timeandeyeUI) feeds with screen/visibility facts. Times are in the
    // monotonic systemUptime domain — plain numbers here.

    /// Run one sample with desktop-ish defaults, overriding what a
    /// scenario cares about.
    func tick(_ s: FullscreenPose.State, at now: TimeInterval,
              fullscreen: Bool = false, popover: Bool = false,
              autoHide: Bool = false, visible: Bool = true)
        -> FullscreenPose.State {
        FullscreenPose.decide(now: now, looksFullscreen: fullscreen,
                              popoverOpen: popover,
                              menuBarAutoHides: autoHide,
                              visible: visible, state: s)
    }

    c.check("a window OPENS in the fullscreen pose and the grace holds it there") {
        // Opening from the popover reveals the menu bar, so the heuristic
        // reads non-fullscreen at exactly the open instant — the grace is
        // what stops macOS evicting a fresh window from a fullscreen Space.
        var s = FullscreenPose.State(openedAt: 100)
        try expect(s.floating, "must open floating")
        for t in stride(from: 100.0, to: 100 + FullscreenPose.graceSeconds, by: 1) {
            s = tick(s, at: t)
            try expect(s.floating, "demoted during grace at t=\(t)")
        }
    }

    c.check("grace samples do not pre-spend the stickiness") {
        // The old 3-sample streak counted DURING the grace, so protection
        // was already gone at grace expiry. Now the settle clock only
        // starts once the grace is over: expiry + settleSeconds of
        // continuous non-fullscreen before demotion, never sooner.
        var s = FullscreenPose.State(openedAt: 0)
        var t = 0.0
        while t < FullscreenPose.graceSeconds { s = tick(s, at: t); t += 1 }
        let graceEnd = FullscreenPose.graceSeconds
        s = tick(s, at: graceEnd)
        try expect(s.floating, "demoted at grace expiry with zero settle run")
        s = tick(s, at: graceEnd + FullscreenPose.settleSeconds - 0.5)
        try expect(s.floating, "demoted before the settle run completed")
        s = tick(s, at: graceEnd + FullscreenPose.settleSeconds)
        try expect(!s.floating, "a completed settle run must demote")
    }

    c.check("the settle streak is TIME-based — apply bursts advance nothing") {
        // SwiftUI render bursts used to drive extra applies; three samples
        // arrived inside a second and spent the whole 3-sample streak.
        // Many samples at the SAME instant must count as no elapsed time.
        var s = FullscreenPose.State(openedAt: 0)
        let t = FullscreenPose.graceSeconds + 1
        for _ in 0..<50 { s = tick(s, at: t) }
        try expect(s.floating, "a burst at one instant spent the stickiness")
    }

    c.check("a brief menu-bar reveal over real fullscreen never evicts") {
        // Pointer-at-top clock-glance: the heuristic reads non-fullscreen
        // while the bar is revealed, then fullscreen again when it
        // re-hides. Any reveal shorter than settleSeconds resets cleanly.
        var s = FullscreenPose.State(openedAt: 0)
        var t = FullscreenPose.graceSeconds + 10
        s = tick(s, at: t, fullscreen: true)
        for _ in 0..<4 { t += 1; s = tick(s, at: t) }        // 4 s reveal
        try expect(s.floating, "a \(4)s glance evicted the window")
        t += 1
        s = tick(s, at: t, fullscreen: true)                 // bar re-hides
        for _ in 0..<4 { t += 1; s = tick(s, at: t) }        // glance again
        try expect(s.floating, "the run must reset on a fullscreen sample")
    }

    c.check("popover open HOLDS sampling — no demotion however long it stays up") {
        // The app KNOWS its own popover is the reason the menu bar is
        // showing; a user holding it open past the grace must not settle a
        // window off a fullscreen Space.
        var s = FullscreenPose.State(openedAt: 0)
        for t in stride(from: FullscreenPose.graceSeconds + 1, to: 120, by: 1) {
            s = tick(s, at: t, popover: true)
            try expect(s.floating, "popover hold failed at t=\(t)")
        }
        // And after it closes, a FULL settle run is still required.
        s = tick(s, at: 120)
        try expect(s.floating, "demoted immediately after popover close")
        s = tick(s, at: 120 + FullscreenPose.settleSeconds)
        try expect(!s.floating, "settle must resume once the popover closes")
    }

    c.check("popover hold does not PROMOTE a settled desktop window") {
        // Hold means freeze, both ways: a window already settled on a
        // plain desktop stays plain when the popover opens.
        var s = FullscreenPose.State(openedAt: 0)
        s.floating = false
        s.graceUntil = 0
        s = tick(s, at: 50, popover: true)
        try expect(!s.floating, "popover open must not float a settled window")
    }

    c.check("hidden windows keep MAINTAINING the fullscreen-capable pose") {
        // AppKit re-asserts flags on hidden retained windows, so a pose
        // parked once on hide would not stick — and macOS decides the
        // Space at show time, before any post-show tick. The hidden tick
        // must keep the pose fullscreen-capable so a reopen orders front
        // already wearing it.
        var s = FullscreenPose.State(openedAt: 0)
        s.floating = false                          // settled on a desktop…
        s.graceUntil = 0
        s = tick(s, at: 50, visible: false)         // …then closed
        try expect(s.floating, "hidden maintenance must restore the pose")
        for t in stride(from: 51.0, to: 70, by: 1) {
            s = tick(s, at: t, visible: false)
            try expect(s.floating, "hidden pose lost at t=\(t)")
        }
        // Reopen: the view restarts the grace at the show instant.
        s.restartGrace(at: 70)
        s = tick(s, at: 70)
        try expect(s.floating, "reopen must hold the pose through the grace")
        try expectEq(s.graceUntil, 70 + FullscreenPose.graceSeconds)
    }

    c.check("menu-bar auto-hide users never float — not even in grace or fullscreen") {
        // With System Settings menu-bar auto-hide, visibleFrame reaches
        // the top on EVERY desktop: the heuristic would read permanent
        // fullscreen and every window would float + join all Spaces
        // forever. The behaviour is disabled wholesale for those users.
        var s = FullscreenPose.State(openedAt: 0)
        s = tick(s, at: 1, fullscreen: true, autoHide: true)   // inside grace
        try expect(!s.floating, "auto-hide mode must never float")
        s = tick(s, at: 100, fullscreen: true, autoHide: true)
        try expect(!s.floating)
        s = tick(s, at: 101, autoHide: true, visible: false)
        try expect(!s.floating, "auto-hide beats hidden maintenance too")
    }

    c.check("a settled window re-floats the moment its screen looks fullscreen") {
        // The user takes an app fullscreen on the Space a settled themed
        // window lives on: it must promote immediately, no grace needed.
        var s = FullscreenPose.State(openedAt: 0)
        s.floating = false
        s.graceUntil = 0
        s = tick(s, at: 50, fullscreen: true)
        try expect(s.floating)
    }

    c.check("grace is monotonic-clock arithmetic — wall jumps cannot stretch it") {
        // graceUntil used to be a Date(): an NTP step backwards stretched
        // the grace (or killed it forwards). The API deals only in the
        // caller's uptime domain, so the deadline is a plain offset.
        let s = FullscreenPose.State(openedAt: 1_000)
        try expectEq(s.graceUntil, 1_000 + FullscreenPose.graceSeconds)
        // Uptime never goes backwards; the state holds no Date anywhere,
        // so there is no wall-clock input left to jump. Pin the settle
        // constant while here — it is the "~5 s continuous look" contract.
        try expect(FullscreenPose.settleSeconds >= 5,
                   "settle stickiness must represent >=5s of continuous non-fullscreen look")
    }
}

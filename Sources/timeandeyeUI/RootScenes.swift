import SwiftUI
import AppKit
import timeandeyeCore
import timeandeyeMac

/// The full scene set, shared by every app flavour: the Community executable
/// in this repo and the Pro executable (private repo) are both thin @main
/// wrappers that own an AppController and return these scenes — Pro registers
/// its paid backends on the controller first.
public enum AndeyeScenes {
    @MainActor @SceneBuilder
    public static func body(controller: AppController) -> some Scene {
        MenuBarExtra {
            PopoverView(controller: controller)
        } label: {
            // The ENTIRE label is one controller-rendered image (mark +
            // elapsed text in a reserved-width column). Three generations of
            // SwiftUI-side width defences (figure-space pad, monospacedDigit,
            // hidden sizing templates, measured minWidth) each still let the
            // mark shift on seconds ticks — MenuBarExtra label rendering does
            // not reliably honour the layout SwiftUI computes. An image's
            // width is not negotiable. See AndeyeLogoImage.label.
            Image(nsImage: controller.logoImage)
                .onAppear {
                    NSApp.setActivationPolicy(.accessory)
                    controller.startUp()
                }
        }
        .menuBarExtraStyle(.window)

        // One Time window — timeline or pie, flipped in place (click a preview).
        Window("Time&I", id: "time") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindowView },
                                        set: { controller.timeWindowView = $0 }),
                          isPrimary: true)
        }
        .defaultSize(width: 980, height: 460)

        // The optional second Time window (control/right-click a preview), so you
        // can see both views at once.
        Window("Time&I · 2nd view", id: "time2") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindow2View },
                                        set: { controller.timeWindow2View = $0 }),
                          isPrimary: false)
        }
        .defaultSize(width: 980, height: 460)

        Window("Time&I Review", id: "review") {
            ReviewView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 640, height: 420)

        Window("Time&I Settings", id: "settings") {
            SettingsView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 460, height: 480)

        Window("Time&I Context Rules", id: "rules") {
            RulesLedgerView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 460, height: 420)
    }
}

/// Make a window come to the user's CURRENT Space when opened, instead of
/// yanking the user across to whichever Space the window was last on. Fixes the
/// "click the gear on Desktop 2 and get thrown to Desktop 1" jump.
private struct ActiveSpaceWindow: NSViewRepresentable {
    var windowID: String?
    /// Runtime override for the host NSWindow's title. A SwiftUI Window's title
    /// is static, so views that change what they show (the Time window flips
    /// between timeline and pie) set it here instead. Nil = leave the title be.
    var title: String?

    /// Applies the window config the moment the view lands in its window —
    /// synchronously, BEFORE the window is first ordered front. The previous
    /// deferred (async) apply lost the race: macOS decides the Space
    /// transition when the window is shown, so behaviours set a runloop later
    /// changed nothing and opening over a fullscreen app still switched Space
    /// (Martin, 2026-07-09 — twice).
    final class SpaceJoiningView: NSView {
        var windowID: String?
        var title: String?
        /// Self-owned re-check cadence. The level decision below must track
        /// the screen's fullscreen-look over time, and riding SwiftUI
        /// re-renders for that proved uneven: clock-driven windows re-render
        /// ~1Hz, but the review drawer re-renders only on queue changes, so
        /// its level never updated after attach and it alone failed to float
        /// over fullscreen apps (Martin, 2026-07-10 — timeline and settings
        /// floated, the drawer didn't). A timer owned HERE gives every
        /// window the same cadence regardless of how often SwiftUI renders.
        private var recheck: Timer?
        private var screenObserver: NSObjectProtocol?
        /// Fix nine state (Martin, 2026-07-10 morning). Two blind spots:
        /// (1) Opening from the menu-bar popover REVEALS the menu bar, so at
        ///     that instant visibleFrame no longer reaches the screen top and
        ///     a freshly opened window read "not fullscreen" — it attached at
        ///     normal level and macOS evicted it to another Space (his
        ///     "Settings and Review open in a separate space"), while the
        ///     already-open timeline, still carrying canJoinAllSpaces from
        ///     attach, floated fine. Windows therefore OPEN in the
        ///     fullscreen-capable pose unconditionally and only SETTLE after
        ///     a grace period — by which time the menu bar has re-hidden if
        ///     the Space really is fullscreen.
        /// (2) canJoinAllSpaces was permanent, so every themed window
        ///     followed the user to every Space (his "follows to any other
        ///     space"). It now tracks the same decision as level and is
        ///     dropped once the window settles on an ordinary desktop.
        /// The demotion is sticky — three consecutive non-fullscreen samples
        /// — so a transient menu-bar reveal over a fullscreen app cannot
        /// flicker the window off the Space it is overlaying.
        private var graceUntil = Date.distantPast
        private var nonFullscreenStreak = 0
        private var wasVisible = false
        private var didInitialApply = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            recheck?.invalidate()
            recheck = nil
            if let observer = screenObserver {
                NotificationCenter.default.removeObserver(observer)
                screenObserver = nil
            }
            guard window != nil else { return }
            graceUntil = Date().addingTimeInterval(4)
            nonFullscreenStreak = 0
            wasVisible = false
            didInitialApply = false
            applyToWindow()
            recheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in self?.applyToWindow()
            }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.applyToWindow() }
            }
        }
        deinit {
            recheck?.invalidate()
            if let observer = screenObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        func applyToWindow() {
            guard let w = window else { return }
            // A stable identity for code that recognises this window (the
            // timeline scroll-pan monitor) without a title match. Cheap and
            // safe on hidden windows, so it runs unconditionally.
            if let windowID, w.identifier?.rawValue != windowID {
                w.identifier = NSUserInterfaceItemIdentifier(windowID)
            }
            // Retitle when the hosted view changes what it shows. Idempotent
            // like the identifier set above — only touch it when it differs.
            if let title, w.title != title {
                w.title = title
            }
            // Space/level management runs only for windows that are shown
            // (or about to be, on the initial pre-display apply): AppKit
            // re-asserts flags on HIDDEN retained windows, so touching them
            // every tick churned behaviours and wrote a log line per second
            // for a closed timeline (Martin's 11:18 grep, 2026-07-10).
            let visible = w.isVisible
            if !visible && didInitialApply {
                wasVisible = false
                return
            }
            if visible && !wasVisible && didInitialApply {
                // A retained window re-shown (SwiftUI reopens the same
                // NSWindow): restart the grace so a reopen never lands at
                // normal level over a fullscreen app.
                graceUntil = Date().addingTimeInterval(4)
                nonFullscreenStreak = 0
            }
            wasVisible = visible
            didInitialApply = true
            // Fullscreen-look heuristic: menu bar hidden ⇒ visibleFrame
            // reaches the top of the screen. Blind while the menu bar is
            // transiently revealed (popover open, pointer at top) — the
            // grace + sticky streak below cover exactly those windows.
            let screen = w.screen ?? NSScreen.main
            let looksFullscreen = screen.map {
                $0.visibleFrame.maxY >= $0.frame.maxY - 1 } ?? false
            if looksFullscreen { nonFullscreenStreak = 0 } else { nonFullscreenStreak += 1 }
            let wantFullscreenPose = looksFullscreen
                || Date() < graceUntil
                || (w.level == .floating && nonFullscreenStreak < 3)
            // Flag history, all evidenced by Martin's log pastes (2026-07-09):
            // SwiftUI Window scenes ship with .fullScreenNone set, which
            // poisoned every insert-only fix (raw 131841); moveToActiveSpace
            // never targets a fullscreen Space; the one arrangement PROVEN to
            // overlay fullscreen apps on this machine is the notification
            // panel's canJoinAllSpaces + fullScreenAuxiliary + a floating
            // LEVEL (normal-level windows are simply evicted). The pose is
            // now CONDITIONAL: canJoinAllSpaces + floating while the screen
            // looks fullscreen (or during the open/reopen grace), plain
            // fullScreenAuxiliary + normal level once settled on an ordinary
            // desktop — so windows neither follow the user across Spaces nor
            // squat above other apps in normal use.
            var behaviours = w.collectionBehavior
            behaviours.remove([.fullScreenNone, .fullScreenPrimary, .moveToActiveSpace])
            behaviours.insert(.fullScreenAuxiliary)
            if wantFullscreenPose {
                behaviours.insert(.canJoinAllSpaces)
            } else {
                behaviours.remove(.canJoinAllSpaces)
            }
            if w.collectionBehavior != behaviours {
                w.collectionBehavior = behaviours
                DebugLog.write("window \(windowID ?? w.title): behaviours -> \(behaviours.rawValue), level \(w.level.rawValue), visible \(visible), onActiveSpace \(w.isOnActiveSpace)")
            }
            let wantedLevel: NSWindow.Level = wantFullscreenPose ? .floating : .normal
            if w.level != wantedLevel {
                w.level = wantedLevel
                DebugLog.write("window \(windowID ?? w.title): level -> \(w.level.rawValue) (fullscreen-look \(looksFullscreen), streak \(nonFullscreenStreak)), onActiveSpace \(w.isOnActiveSpace)")
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = SpaceJoiningView()
        view.windowID = windowID
        view.title = title
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SpaceJoiningView else { return }
        view.windowID = windowID
        view.title = title
        // Deferred here (unlike the sync first-attach apply above): re-renders
        // arrive mid SwiftUI update pass, where touching the window is safer a
        // runloop later. Only the title/id ever change on this path.
        DispatchQueue.main.async { [weak view] in view?.applyToWindow() }
    }
}

extension View {
    func openOnActiveSpace(id windowID: String? = nil, title: String? = nil) -> some View {
        background(ActiveSpaceWindow(windowID: windowID, title: title))
    }
}

/// App activation that never yanks the Space. `NSApp.activate` while the app
/// has no window on the ACTIVE Space makes macOS switch to a Space that does
/// have its windows — and SwiftUI's `openWindow` is asynchronous, so the old
/// open-then-activate pairs activated a still-window-less app and switched
/// away from fullscreen apps regardless of any collectionBehavior flag on the
/// window itself (Martin, 2026-07-09, after two window-flag fixes weren't it).
/// Call AFTER `openWindow`: it waits — runloop turns, not wall time — until a
/// normal-level window is visible on the CURRENT Space (the flags applied at
/// first attach put it there), then activates; at that point activation has
/// nothing to switch away to.
@MainActor
enum AndeyeWindows {
    static func activateOnceVisible(_ retriesLeft: Int = 40) {
        // Floating counts: over a fullscreen app the themed windows live at
        // .floating (SpaceJoiningView), and a gate that only accepted
        // .normal never fired there — the open finished without activation
        // and the window was left behind on another Space (Martin,
        // 2026-07-10 morning).
        if NSApp.windows.contains(where: {
            $0.isVisible && $0.isOnActiveSpace
                && ($0.level == .normal || $0.level == .floating) }) {
            NSApp.activate(ignoringOtherApps: true)
        } else if retriesLeft > 0 {
            DispatchQueue.main.async { activateOnceVisible(retriesLeft - 1) }
        } else {
            // Diagnostic, not control flow: if no window ever satisfied the
            // gate, the Space decision went wrong again — dump every window's
            // state so the NEXT report comes with data instead of symptoms.
            for w in NSApp.windows where w.level == .normal || w.level == .floating {
                DebugLog.write("activate-gave-up: \(w.identifier?.rawValue ?? w.title) visible \(w.isVisible), onActiveSpace \(w.isOnActiveSpace), behaviours \(w.collectionBehavior.rawValue)")
            }
        }
    }
}

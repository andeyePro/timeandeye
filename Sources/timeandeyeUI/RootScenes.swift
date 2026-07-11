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
                // The popover REVEALS the menu bar, blinding the
                // fullscreen-look heuristic for exactly as long as it is
                // open. The app knows when that is — tell the pose logic,
                // which HOLDS sampling while the flag is up
                // (FullscreenPose.decide / SpaceJoiningView).
                .onAppear { AndeyeWindows.popoverIsOpen = true }
                .onDisappear { AndeyeWindows.popoverIsOpen = false }
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
            ReviewView(controller: controller).openOnActiveSpace(id: "review")
        }
        .defaultSize(width: 640, height: 420)

        Window("Time&I Settings", id: "settings") {
            SettingsView(controller: controller).openOnActiveSpace(id: "settings")
        }
        .defaultSize(width: 460, height: 480)

        Window("Time&I Context Rules", id: "rules") {
            RulesLedgerView(controller: controller).openOnActiveSpace(id: "rules")
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
        private var openObserver: NSObjectProtocol?
        /// Fullscreen fix thirteen (Martin, 2026-07-11): a green-buttoned
        /// window came back from Esc frozen, unclickable and sinking behind
        /// other windows. Cause: .fullScreen leaves the styleMask BEFORE the
        /// exit animation completes, so the styleMask guard below stopped
        /// protecting the window mid-transition and the 1 Hz timer mutated
        /// collectionBehavior/level while macOS was still animating the
        /// Space — which wedges the window. These track the transition via
        /// the will/did notifications and hold every mutation until it ends,
        /// plus a settle margin.
        private var transitionObservers: [NSObjectProtocol] = []
        private var inFullscreenTransition = false
        private var transitionHoldUntil: TimeInterval = 0
        /// Fix nine (Martin, 2026-07-10 morning) closed two blind spots:
        /// the popover's menu-bar reveal blinded the heuristic at exactly
        /// open time (fresh windows attached at normal level and macOS
        /// evicted them to another Space), and canJoinAllSpaces was
        /// permanent (every themed window followed the user to every
        /// Space). The review pass then moved the whole decision into
        /// `FullscreenPose.decide` (timeandeyeMac — pure, check-covered):
        /// open/reopen grace, a TIME-based sticky settle (~5 s continuous,
        /// immune to apply bursts), an explicit popover-open hold, hidden-
        /// window pose maintenance, and a menu-bar-auto-hide opt-out. This
        /// view only gathers the AppKit facts and applies the verdict.
        private var pose = FullscreenPose.State(
            openedAt: ProcessInfo.processInfo.systemUptime)
        private var wasVisible = false
        private var didInitialApply = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Lifecycle teardown lives HERE (window == nil is the reliable
            // detach path, always on the main thread) — deinit below is
            // only a backstop, because it can run off the installing
            // thread and Timer.invalidate/removeObserver are not
            // thread-safe to the runloop they were scheduled on.
            recheck?.invalidate()
            recheck = nil
            if let observer = screenObserver {
                NotificationCenter.default.removeObserver(observer)
                screenObserver = nil
            }
            if let observer = openObserver {
                NotificationCenter.default.removeObserver(observer)
                openObserver = nil
            }
            for observer in transitionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            transitionObservers = []
            inFullscreenTransition = false
            transitionHoldUntil = 0
            guard window != nil else { return }
            pose = FullscreenPose.State(
                openedAt: ProcessInfo.processInfo.systemUptime)
            wasVisible = false
            didInitialApply = false
            applyToWindow()
            // Not Timer.scheduledTimer: that installs in .default mode
            // only, so ticks stopped during menu tracking and window
            // drags. .common keeps the cadence through both.
            let timer = Timer(timeInterval: 1, repeats: true) {
                [weak self] _ in self?.applyToWindow()
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            recheck = timer
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.applyToWindow() }
            }
            // User-open grant (see AndeyeWindows.openRequested): SYNCHRONOUS
            // — no queue hop — so a visible desktop-settled window regains
            // the fullscreen-capable pose in the click's own runloop turn,
            // before SwiftUI's deferred order-front lets macOS decide the
            // Space.
            openObserver = NotificationCenter.default.addObserver(
                forName: AndeyeWindows.openRequested, object: nil,
                queue: nil) { [weak self] note in
                guard let self, Thread.isMainThread else { return }
                // On-main proven by the guard above; assumeIsolated makes
                // that visible to the compiler (the bare call was warning
                // 'main actor-isolated method in a synchronous nonisolated
                // context' on every build — Martin's 04:14 paste).
                MainActor.assumeIsolated {
                    // Scoped: only the window being opened re-graces (see
                    // AndeyeWindows.openGrantApplies) — granting every window
                    // put them all in the auxiliary pose, which blocked the
                    // green button for 4s after any open.
                    guard AndeyeWindows.openGrantApplies(
                        opened: note.userInfo?["id"] as? String,
                        windowID: self.windowID) else { return }
                    self.pose.restartGrace(at: ProcessInfo.processInfo.systemUptime)
                    self.applyToWindow()
                }
            }
            // Fullscreen fix thirteen: bracket macOS's enter/exit animations.
            let starts = [NSWindow.willEnterFullScreenNotification,
                          NSWindow.willExitFullScreenNotification]
            let ends = [NSWindow.didEnterFullScreenNotification,
                        NSWindow.didExitFullScreenNotification]
            for name in starts {
                transitionObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.inFullscreenTransition = true
                })
            }
            for name in ends {
                transitionObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.inFullscreenTransition = false
                    // Settle margin: AppKit finishes rearranging Spaces a
                    // beat after `did…` fires; mutating immediately can
                    // still catch the tail of the animation. NO fresh grace
                    // here — grace means the auxiliary pose, and auxiliary
                    // windows can't green-button into their own fullscreen,
                    // which broke an immediate re-fullscreen after an exit
                    // (Martin, 2026-07-11). Exiting lands on a desktop; the
                    // 1 Hz decide() re-floats it if the screen genuinely
                    // still looks fullscreen.
                    self.transitionHoldUntil = ProcessInfo.processInfo.systemUptime + 2
                })
            }
        }
        deinit {
            // Backstop only (see viewDidMoveToWindow). deinit may run on
            // any thread; hop the captured timer/observer to main, where
            // they were installed.
            let timer = recheck
            let observers = [screenObserver, openObserver].compactMap { $0 }
                + transitionObservers
            let cleanup = {
                timer?.invalidate()
                for observer in observers {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
            if Thread.isMainThread { cleanup() }
            else { DispatchQueue.main.async(execute: cleanup) }
        }
        /// The cheap identity upkeep — the only work SwiftUI re-renders
        /// are allowed to trigger. Sampling stays with the timer: when
        /// re-renders also drove full applies, render bursts fed the
        /// settle streak far faster than 1 Hz and spent the stickiness in
        /// under a second.
        func applyIdentity() {
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
        }
        func applyToWindow() {
            guard let w = window else { return }
            applyIdentity()
            let visible = w.isVisible
            if visible && !wasVisible && didInitialApply {
                // A retained window re-shown (SwiftUI reopens the same
                // NSWindow): restart the grace so a reopen never settles
                // at normal level over a fullscreen app. (The hidden
                // maintenance below means it already WEARS the fullscreen
                // pose at the show instant — macOS decides the Space then,
                // up to a tick before this branch can run.)
                pose.restartGrace(at: ProcessInfo.processInfo.systemUptime)
            }
            wasVisible = visible
            didInitialApply = true
            // A window that is IN ITS OWN native fullscreen Space (green
            // button) belongs to macOS: touching flags or level mid-
            // fullscreen risks breaking the Space or its exit animation.
            // Leave it entirely alone until it comes back.
            if w.styleMask.contains(.fullScreen) { return }
            // …and so does a window mid enter/exit ANIMATION: .fullScreen
            // drops from the styleMask before the exit finishes, and
            // mutating flags in that gap wedged a window solid (fix
            // thirteen — Martin, 2026-07-11). Hold until the transition
            // ends plus a settle margin.
            if inFullscreenTransition
                || ProcessInfo.processInfo.systemUptime < transitionHoldUntil { return }
            // Fullscreen-look heuristic: menu bar hidden ⇒ visibleFrame
            // reaches the top of the screen. Blind while the menu bar is
            // transiently revealed (popover open, pointer at top) — the
            // grace, popover hold and sticky settle in FullscreenPose
            // cover exactly those windows.
            let screen = w.screen ?? NSScreen.main
            let looksFullscreen = screen.map {
                $0.visibleFrame.maxY >= $0.frame.maxY - 1 } ?? false
            // The System Settings menu-bar auto-hide preference (global
            // domain, visible through the standard search list). When set,
            // the heuristic is permanently blind — FullscreenPose disables
            // the float behaviour wholesale for those users.
            let menuBarAutoHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
            let before = pose.floating
            pose = FullscreenPose.decide(
                now: ProcessInfo.processInfo.systemUptime,
                looksFullscreen: looksFullscreen,
                popoverOpen: AndeyeWindows.popoverIsOpen,
                menuBarAutoHides: menuBarAutoHides,
                visible: visible,
                state: pose)
            let wantFullscreenPose = pose.floating
            // Hidden retained windows are MAINTAINED, silently: AppKit
            // re-asserts flags on them (per-second churn in Martin's 11:18
            // grep, 2026-07-10), so a pose parked once on hide would not
            // stick — the sets below keep running, but the log lines are
            // gated to visible windows or actual decision changes.
            let logworthy = visible || before != wantFullscreenPose
            // Flag history, all evidenced by Martin's log pastes (2026-07-09):
            // SwiftUI Window scenes ship with .fullScreenNone set, which
            // poisoned every insert-only fix (raw 131841); moveToActiveSpace
            // never targets a fullscreen Space; the one arrangement PROVEN to
            // overlay fullscreen apps on this machine is the notification
            // panel's canJoinAllSpaces + fullScreenAuxiliary + a floating
            // LEVEL (normal-level windows are simply evicted). The pose is
            // CONDITIONAL: canJoinAllSpaces + floating while the screen
            // looks fullscreen (or during the open/reopen grace), plain
            // fullScreenAuxiliary + normal level once settled on an ordinary
            // desktop — so windows neither follow the user across Spaces nor
            // squat above other apps in normal use.
            // The green button needs .fullScreenPrimary to create the
            // window's OWN fullscreen Space — the unconditional strip left
            // it zooming over whatever it floated above instead (Martin,
            // 2026-07-10 afternoon). Primary and auxiliary are exclusive:
            // the desktop pose is a normal window (primary — green button
            // works), the fullscreen-capable pose is an auxiliary overlay
            // (green-buttoning WHILE floating over another app's fullscreen
            // still can't spawn a Space — macOS constraint of auxiliary
            // windows; drop out of the other app's fullscreen first).
            var behaviours = w.collectionBehavior
            behaviours.remove([.fullScreenNone, .moveToActiveSpace])
            if wantFullscreenPose {
                behaviours.remove(.fullScreenPrimary)
                behaviours.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            } else {
                behaviours.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
                behaviours.insert(.fullScreenPrimary)
            }
            if w.collectionBehavior != behaviours {
                w.collectionBehavior = behaviours
                if logworthy {
                    // Log the flags READ BACK from the window, never the
                    // requested value: the fullScreenNone saga was only
                    // diagnosable because the log showed what AppKit
                    // actually kept.
                    DebugLog.write("window \(windowID ?? w.title): behaviours -> \(w.collectionBehavior.rawValue), level \(w.level.rawValue), visible \(visible), onActiveSpace \(w.isOnActiveSpace)")
                }
            }
            let wantedLevel: NSWindow.Level = wantFullscreenPose ? .floating : .normal
            if w.level != wantedLevel {
                w.level = wantedLevel
                if logworthy {
                    DebugLog.write("window \(windowID ?? w.title): level -> \(w.level.rawValue) (fullscreen-look \(looksFullscreen), autoHide \(menuBarAutoHides), popover \(AndeyeWindows.popoverIsOpen)), visible \(visible), onActiveSpace \(w.isOnActiveSpace)")
                }
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
        // Deferred (unlike the sync first-attach apply above): re-renders
        // arrive mid SwiftUI update pass, where touching the window is safer
        // a runloop later. IDENTITY upkeep only — the timer owns sampling,
        // so render frequency can never feed the settle streak.
        DispatchQueue.main.async { [weak view] in view?.applyIdentity() }
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
    /// True while the app's own MenuBarExtra popover is open (set from its
    /// content's onAppear/onDisappear in AndeyeScenes.body). The popover
    /// reveals the menu bar, which blinds SpaceJoiningView's fullscreen
    /// heuristic — the pose logic HOLDS sampling while this is up.
    static var popoverIsOpen = false

    /// Posted synchronously at the start of every themed-window open (all
    /// open sites funnel through `activateOnceVisible`). A window the user
    /// left OPEN on a desktop Space is visible + settled, so neither the
    /// hidden-window maintenance nor the show-transition grace protects it
    /// — and the popover blinds promotion at exactly click time. Result
    /// (Martin, 2026-07-10 afternoon): clicking a popover icon over a
    /// fullscreen app needed several clicks before the window surfaced.
    /// Every SpaceJoiningView restarts its open grace on this note, in the
    /// SAME runloop turn as the click — ahead of SwiftUI's deferred
    /// order-front, so the window is fullscreen-capable when macOS decides
    /// the Space. A 4s float on windows that weren't the one opened is the
    /// accepted cost.
    static let openRequested = Notification.Name("andeyeThemedWindowOpenRequested")

    /// True when a SpaceJoiningView with `windowID` should honour an open
    /// grant for the openWindow scene `opened`. Scoped (Martin, 2026-07-10
    /// late afternoon): the original all-windows grant put EVERY window
    /// into the auxiliary overlay pose for 4s on any open, and auxiliary
    /// windows cannot enter their own fullscreen — his green button worked
    /// or failed depending on whether anything had been opened in the
    /// previous few seconds. Nil on either side stays permissive (an
    /// unidentified view or an unlabelled open grants broadly — safe, just
    /// less precise). The Time scenes ("time"/"time2") host views whose
    /// ids are the VIEW mode ("timeline"/"spent").
    static func openGrantApplies(opened: String?, windowID: String?) -> Bool {
        guard let opened, let windowID else { return true }
        if opened == windowID { return true }
        return (opened == "time" || opened == "time2")
            && (windowID == "timeline" || windowID == "spent")
    }

    static func activateOnceVisible(opened: String? = nil, _ retriesLeft: Int = 40) {
        if retriesLeft == 40 {   // the entry call, not a retry turn
            NotificationCenter.default.post(name: openRequested, object: nil,
                                            userInfo: opened.map { ["id": $0] })
        }
        // Floating counts: over a fullscreen app the themed windows live at
        // .floating (SpaceJoiningView), and a gate that only accepted
        // .normal never fired there — the open finished without activation
        // and the window was left behind on another Space (Martin,
        // 2026-07-10 morning).
        let acceptable: (NSWindow) -> Bool = {
            $0.isVisible && $0.isOnActiveSpace
                && ($0.level == .normal || $0.level == .floating)
        }
        // With an id, activate THE WINDOW BEING OPENED and make it key —
        // activating the app on the first acceptable window brought some
        // OTHER window forward while the requested one stayed buried, which
        // read as "the settings gear needs two clicks" (Martin, 2026-07-11).
        if let id = opened {
            if let target = NSApp.windows.first(where: { w in
                w.identifier != nil && acceptable(w)
                    && openGrantApplies(opened: id, windowID: w.identifier?.rawValue)
            }) {
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
            } else if retriesLeft > 0 {
                DispatchQueue.main.async { activateOnceVisible(opened: id, retriesLeft - 1) }
            } else if NSApp.windows.contains(where: acceptable) {
                NSApp.activate(ignoringOtherApps: true)   // best effort
            }
            return
        }
        if NSApp.windows.contains(where: acceptable) {
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

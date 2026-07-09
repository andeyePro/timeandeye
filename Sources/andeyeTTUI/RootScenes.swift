import SwiftUI
import AppKit
import andeyeTTCore
import andeyeTTMac

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
        Window("Time&i", id: "time") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindowView },
                                        set: { controller.timeWindowView = $0 }),
                          isPrimary: true)
        }
        .defaultSize(width: 980, height: 460)

        // The optional second Time window (control/right-click a preview), so you
        // can see both views at once.
        Window("Time&i · 2nd view", id: "time2") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindow2View },
                                        set: { controller.timeWindow2View = $0 }),
                          isPrimary: false)
        }
        .defaultSize(width: 980, height: 460)

        Window("Time&i Review", id: "review") {
            ReviewView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 640, height: 420)

        Window("Time&i Settings", id: "settings") {
            SettingsView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 460, height: 480)

        Window("Time&i Context Rules", id: "rules") {
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToWindow()
        }
        func applyToWindow() {
            guard let w = window else { return }
            // Idempotent: also called from updateNSView on every re-render
            // (~1Hz from the menu clock), so only touch the window when
            // something actually differs — no per-render churn.
            //
            // Fullscreen-join history, all evidenced by Martin's log pastes
            // (2026-07-09): SwiftUI Window scenes ship with .fullScreenNone
            // set, which poisoned every insert-only fix (raw 131841). With
            // the poison bit stripped, a clean moveToActiveSpace +
            // fullScreenAuxiliary (raw 131330) STILL bounced — the log's
            // "visible true, onActiveSpace false" at display — so
            // moveToActiveSpace simply never targets a fullscreen Space.
            // What remains is the one arrangement PROVEN to overlay
            // fullscreen apps on this machine — the app's own notification
            // panel's canJoinAllSpaces + fullScreenAuxiliary — which has
            // never yet run clean (the earlier canJoinAllSpaces attempt
            // predates the poison-bit discovery). Trade: the windows sit on
            // every Space while open; Martin accepted "anything if
            // necessary". If even this bounces, the flags are exonerated
            // and the next lever is window LEVEL (the panel floats at
            // .statusBar).
            var behaviours = w.collectionBehavior
            behaviours.remove([.fullScreenNone, .fullScreenPrimary, .moveToActiveSpace])
            behaviours.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            if w.collectionBehavior != behaviours {
                w.collectionBehavior = behaviours
                DebugLog.write("window \(windowID ?? w.title): behaviours -> \(w.collectionBehavior.rawValue), level \(w.level.rawValue), visible \(w.isVisible), onActiveSpace \(w.isOnActiveSpace)")
            }
            // A stable identity for code that recognises this window (the
            // timeline scroll-pan monitor) without a title match.
            if let windowID, w.identifier?.rawValue != windowID {
                w.identifier = NSUserInterfaceItemIdentifier(windowID)
            }
            // Retitle when the hosted view changes what it shows. Idempotent
            // like the identifier set above — only touch it when it differs.
            if let title, w.title != title {
                w.title = title
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
        if NSApp.windows.contains(where: {
            $0.isVisible && $0.isOnActiveSpace && $0.level == .normal }) {
            NSApp.activate(ignoringOtherApps: true)
        } else if retriesLeft > 0 {
            DispatchQueue.main.async { activateOnceVisible(retriesLeft - 1) }
        } else {
            // Diagnostic, not control flow: if no window ever satisfied the
            // gate, the Space decision went wrong again — dump every window's
            // state so the NEXT report comes with data instead of symptoms.
            for w in NSApp.windows where w.level == .normal {
                DebugLog.write("activate-gave-up: \(w.identifier?.rawValue ?? w.title) visible \(w.isVisible), onActiveSpace \(w.isOnActiveSpace), behaviours \(w.collectionBehavior.rawValue)")
            }
        }
    }
}

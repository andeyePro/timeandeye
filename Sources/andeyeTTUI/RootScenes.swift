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
            HStack(spacing: 4) {
                Image(nsImage: controller.logoImage)
                // Tabular digits alone weren't enough: the figure-space pad on
                // single-digit seconds (MenuTitle.text) assumes U+2007 is
                // exactly one tabular-digit wide, which isn't guaranteed by
                // every font — so the real text could still render a hair
                // narrower or wider than its padded neighbour and drag the
                // right-anchored status item's logo with it. Overlaying
                // MenuTitle.sizingTemplates hidden behind the real text makes
                // the ZStack size itself to whichever candidate actually lays
                // out widest, measured, not assumed — the logo stops moving
                // regardless of glyph metrics.
                ZStack(alignment: .leading) {
                    ForEach(controller.menuSizingTemplates, id: \.self) { template in
                        Text(template)
                            .monospacedDigit()
                            .hidden()
                    }
                    Text(controller.menuText)
                        .monospacedDigit()
                }
                // The hidden templates alone did NOT hold the MenuBarExtra
                // label's width (Martin, 2026-07-08: the icon shifts exactly
                // when the time text changes width), so the controller
                // measures the widest candidate with AppKit and the label
                // reserves it explicitly. minWidth, not a fixed frame: if the
                // measurement ever runs a hair low the content still wins and
                // nothing clips — the reservation only stops shrinking.
                .frame(minWidth: controller.menuReservedWidth > 0
                                 ? controller.menuReservedWidth : nil,
                       alignment: .leading)
            }
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
                controller.startUp()
            }
        }
        .menuBarExtraStyle(.window)

        // One Time window — timeline or pie, flipped in place (click a preview).
        Window("andeye Time", id: "time") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindowView },
                                        set: { controller.timeWindowView = $0 }),
                          isPrimary: true)
        }
        .defaultSize(width: 980, height: 460)

        // The optional second Time window (control/right-click a preview), so you
        // can see both views at once.
        Window("andeye Time · 2nd view", id: "time2") {
            TimeContainer(controller: controller,
                          view: Binding(get: { controller.timeWindow2View },
                                        set: { controller.timeWindow2View = $0 }),
                          isPrimary: false)
        }
        .defaultSize(width: 980, height: 460)

        Window("andeye Review", id: "review") {
            ReviewView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 640, height: 420)

        Window("andeye Settings", id: "settings") {
            SettingsView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 460, height: 480)

        Window("andeye Context Rules", id: "rules") {
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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { apply(to: nsView) }

    private func apply(to view: NSView) {
        let windowID = windowID
        DispatchQueue.main.async { [weak view] in
            guard let w = view?.window else { return }
            // Idempotent: updateNSView runs on every re-render (~1Hz from the
            // menu clock), so only touch the window when something actually
            // differs — no per-render churn.
            if !w.collectionBehavior.contains(.moveToActiveSpace) {
                w.collectionBehavior.insert(.moveToActiveSpace)
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
}

extension View {
    func openOnActiveSpace(id windowID: String? = nil, title: String? = nil) -> some View {
        background(ActiveSpaceWindow(windowID: windowID, title: title))
    }
}

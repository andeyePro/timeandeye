import SwiftUI
import AppKit
import AmbitickCore
import AmbitickMac

@main
struct AmbitickApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: controller)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: Self.swatch(controller.menuColour))
                Text(controller.menuText)
            }
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
                controller.startUp()
            }
        }
        .menuBarExtraStyle(.window)

        // One Time window — timeline or pie, flipped in place (click a preview).
        Window("Ambitick Time", id: "time") {
            TimeContainer(controller: controller, view: $controller.timeWindowView, isPrimary: true)
        }
        .defaultSize(width: 980, height: 460)

        // The optional second Time window (control/right-click a preview), so you
        // can see both views at once.
        Window("Ambitick Time · 2nd view", id: "time2") {
            TimeContainer(controller: controller, view: $controller.timeWindow2View, isPrimary: false)
        }
        .defaultSize(width: 980, height: 460)

        Window("Ambitick Review", id: "review") {
            ReviewView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 640, height: 420)

        Window("Ambitick Settings", id: "settings") {
            SettingsView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 460, height: 480)
    }

    /// Small filled circle carrying the certainty colour (non-template so the
    /// menu bar shows it in colour).
    static func swatch(_ colour: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Make a window come to the user's CURRENT Space when opened, instead of
/// yanking the user across to whichever Space the window was last on. Fixes the
/// "click the gear on Desktop 2 and get thrown to Desktop 1" jump.
private struct ActiveSpaceWindow: NSViewRepresentable {
    var windowID: String?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { apply(to: nsView) }

    private func apply(to view: NSView) {
        let windowID = windowID
        DispatchQueue.main.async { [weak view] in
            view?.window?.collectionBehavior.insert(.moveToActiveSpace)
            // A stable identity for code that needs to recognise this window
            // (e.g. the timeline's scroll-pan monitor) without a title match.
            if let windowID { view?.window?.identifier = NSUserInterfaceItemIdentifier(windowID) }
        }
    }
}

extension View {
    func openOnActiveSpace(id windowID: String? = nil) -> some View {
        background(ActiveSpaceWindow(windowID: windowID))
    }
}

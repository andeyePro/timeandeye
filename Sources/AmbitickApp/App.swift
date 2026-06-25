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

        Window("Ambitick Time Spent", id: "spent") {
            SpentView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 640, height: 420)

        Window("Ambitick Timeline", id: "timeline") {
            TimelineView(controller: controller).openOnActiveSpace()
        }
        .defaultSize(width: 980, height: 420)

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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { apply(to: nsView) }

    private func apply(to view: NSView) {
        DispatchQueue.main.async { [weak view] in
            view?.window?.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

extension View {
    func openOnActiveSpace() -> some View { background(ActiveSpaceWindow()) }
}

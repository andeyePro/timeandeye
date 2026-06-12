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
            SpentView(controller: controller)
        }
        .defaultSize(width: 640, height: 420)

        Window("Ambitick Timeline", id: "timeline") {
            TimelineView(controller: controller)
        }
        .defaultSize(width: 980, height: 420)

        Window("Ambitick Review", id: "review") {
            ReviewView(controller: controller)
        }
        .defaultSize(width: 640, height: 420)

        Window("Ambitick Settings", id: "settings") {
            SettingsView(controller: controller)
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

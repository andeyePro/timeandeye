#if os(macOS)
import SwiftUI
import AppKit
import timeandeyeMac
import timeandeyeCore

/// Headless UI snapshots — the agent's eyes (Martin, 13 Aug reply 10: "Can
/// you actually see the UI? Please fix it so you can"). Renders named views
/// to PNG via `ImageRenderer` so a session on the build bridge can pull the
/// images back and LOOK at layout before and after a change. Lives inside
/// timeandeyeUI so it can reach the internal views; the thin
/// `timeandeyeSnapshots` executable just calls `renderAll`.
///
/// The scoped build account has no window session, so `screencapture` can
/// never work there — `ImageRenderer` draws off-screen and does not need
/// one. The controller is a REAL `AppController` writing under the build
/// account's own Application Support (isolated from the user's data by the
/// account boundary); sensors are never started (`startUp()` is not
/// called), so rendering observes nothing and tracks nothing.
public enum SnapshotHarness {
    /// Renders every named view in BOTH appearances (2026-08-14 — a
    /// light-mode contrast bug shipped invisibly while the harness rendered
    /// only the account default); returns "name: path-or-error" lines.
    /// Filenames carry `-light` / `-dark` suffixes.
    @MainActor public static func renderAll(to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = AppController()
        var out: [String] = []
        // A no-dependencies probe FIRST: if this fails, the environment
        // (not a view) is the problem — report it unmistakably.
        out += snap("probe", into: dir, size: .init(width: 320, height: 90)) {
            Text("Time&I snapshot probe").font(.title2).padding()
        }
        for category in SettingsIA.Category.allCases {
            out += snap("settings-\(category.rawValue)", into: dir,
                        size: .init(width: 760, height: 640)) {
                SettingsView(controller: controller, initialCategory: category)
            }
        }
        out += snap("popover", into: dir, size: .init(width: 380, height: 600)) {
            PopoverView(controller: controller)
        }
        out += snap("review", into: dir, size: .init(width: 720, height: 520)) {
            ReviewView(controller: controller)
        }
        out += snap("rules-ledger", into: dir, size: .init(width: 640, height: 480)) {
            RulesLedgerView(controller: controller)
        }
        return out
    }

    /// One view → two PNGs, one per appearance.
    @MainActor private static func snap<V: View>(_ name: String, into dir: URL,
                                                 size: CGSize,
                                                 @ViewBuilder _ view: () -> V) -> [String] {
        [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)].map { suffix, appearance in
            render("\(name)-\(suffix)", into: dir, size: size,
                   appearance: appearance, view)
        }
    }

    @MainActor private static func render<V: View>(_ name: String, into dir: URL,
                                                   size: CGSize,
                                                   appearance: NSAppearance.Name,
                                                   @ViewBuilder _ view: () -> V) -> String {
        // NSHostingView + cacheDisplay, NOT ImageRenderer: ImageRenderer only
        // draws pure SwiftUI — every AppKit-backed container (List,
        // NavigationSplitView, Form on macOS) comes out as a placeholder
        // glyph, which is exactly the chrome Settings/Review/Ledger are made
        // of. An offscreen hosting view draws the real AppKit hierarchy and
        // needs no window session (verified over the SSH bridge).
        _ = NSApplication.shared   // AppKit views need the app object to exist
        let host = NSHostingView(rootView: view()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        // Explicit per-render appearance: dynamic colours (windowBackground,
        // AndeyeTheme.highlight) resolve against the view's effective
        // appearance during cacheDisplay, so this alone flips the render.
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let async SwiftUI layout (List row materialisation) settle one
        // runloop turn before caching.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return "\(name): RENDER FAILED (no bitmap rep)"
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return "\(name): RENDER FAILED (png encode)"
        }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            return "\(name): \(url.path)"
        } catch {
            return "\(name): WRITE FAILED \(error)"
        }
    }
}
#endif

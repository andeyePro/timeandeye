import AppKit
import ApplicationServices
import AmbitickCore

/// Capture and restore a "workspace": every normal window on the current Space
/// and where it sits. Pure public API (CGWindowList to read, NSWorkspace to
/// launch, Accessibility to position) — no private Space/SkyLight calls, so it
/// needs no SIP changes.
///
/// Scope is the current Space: `.optionOnScreenOnly` returns only windows on the
/// active desktop, which is exactly "all windows in this space". We keep *every*
/// window (not one per app), preserving front-to-back order so restore can put
/// each one back even when an app has several windows.
///
/// Restore limitation: macOS gives no public way to force an app to spawn extra
/// windows. So for an app that is already running we place all of its live
/// windows; for one we have to launch fresh, the OS typically opens a single
/// window and we place that. The common workflow (your windows are already
/// open, you re-arrange them) is fully covered.
public enum WorkspaceLayout {
    /// Snapshot every on-screen normal window on the current Space as
    /// app + frame entries, in front-to-back order.
    public static func capture() -> [WindowFrame] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let appsByPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { a, _ in a })
        var out: [WindowFrame] = []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,                 // normal windows
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = appsByPID[pid], let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,                       // not ourselves
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 80, bounds.height > 80 else { continue }         // skip palettes/HUDs
            let title = info[kCGWindowName as String] as? String ?? ""
            out.append(WindowFrame(bundleID: bundleID,
                                   x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                                   w: Double(bounds.width), h: Double(bounds.height),
                                   title: title))
        }
        return out
    }

    /// Launch each app (if needed) and place its windows back where they were.
    /// Needs the Accessibility grant the app already holds.
    public static func apply(_ frames: [WindowFrame]) {
        // Group by app, preserving the captured (front-to-back) order per app.
        var order: [String] = []
        var byApp: [String: [WindowFrame]] = [:]
        for f in frames {
            if byApp[f.bundleID] == nil { order.append(f.bundleID) }
            byApp[f.bundleID, default: []].append(f)
        }
        for bundleID in order {
            guard let wanted = byApp[bundleID],
                  let url = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                guard let pid = app?.processIdentifier else { return }
                // Bring the window count up to what we saved (the app may have
                // launched fresh with one window, or be running with fewer than
                // the layout needs), THEN place each window. Budget = one spawn
                // per missing window plus slack for launch/settle waits.
                ensureWindowCount(pid: pid, target: wanted.count,
                                  attemptsLeft: wanted.count + 8) {
                    placeAll(pid: pid, wanted: wanted)
                }
            }
        }
    }

    /// Drive the app's own "New Window" command until it has at least `target`
    /// windows, then call `done`. We recount every pass so a late-appearing
    /// launch window can't push us more than one window past the target, and the
    /// attempt budget guarantees termination for apps that can't make windows.
    private static func ensureWindowCount(pid: pid_t, target: Int, attemptsLeft: Int,
                                          then done: @escaping () -> Void) {
        let count = liveWindows(pid: pid).count
        if count >= target || attemptsLeft <= 0 {
            // Let the most recently spawned window settle before positioning.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            return
        }
        if count == 0 {
            // Almost certainly still launching — wait for the first window rather
            // than firing menu commands at an app with no menu bar yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ensureWindowCount(pid: pid, target: target,
                                  attemptsLeft: attemptsLeft - 1, then: done)
            }
            return
        }
        // We have a window but need more: ask the app to open one.
        guard spawnWindow(pid: pid) else { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ensureWindowCount(pid: pid, target: target,
                              attemptsLeft: attemptsLeft - 1, then: done)
        }
    }

    /// Make the app open one more window: drive its "New Window" menu item via
    /// Accessibility (deterministic, targeted), falling back to a ⌘N keystroke
    /// after activating it. Returns false only if neither path is available.
    @discardableResult
    private static func spawnWindow(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate()
        if pressMenuItem(pid: pid, titleNeedles: ["new", "window"]) { return true }
        return synthesizeCommandN()
    }

    /// Match each wanted frame to a live AX window — by title first (handles
    /// re-ordering), then by remaining capture order — and position/size it.
    /// Returns how many frames were placed.
    @discardableResult
    private static func placeAll(pid: pid_t, wanted: [WindowFrame]) -> Int {
        let windows = liveWindows(pid: pid)
        guard !windows.isEmpty else { return 0 }

        var available = windows
        var placed = 0

        func place(_ window: AXUIElement, _ frame: WindowFrame) {
            var pos = CGPoint(x: frame.x, y: frame.y)
            if let posValue = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }
            var sz = CGSize(width: frame.w, height: frame.h)
            if let sizeValue = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            placed += 1
        }

        // Pass 1: title matches (only when the saved title is non-empty).
        var leftover: [WindowFrame] = []
        for frame in wanted {
            if !frame.title.isEmpty,
               let idx = available.firstIndex(where: { titleOf($0) == frame.title }) {
                place(available.remove(at: idx), frame)
            } else {
                leftover.append(frame)
            }
        }
        // Pass 2: whatever is left, paired in order with remaining windows.
        for frame in leftover {
            guard !available.isEmpty else { break }
            place(available.removeFirst(), frame)
        }
        return placed
    }

    private static func liveWindows(pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString,
                                            &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows
    }

    private static func titleOf(_ element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString,
                                            &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    private static func roleOf(_ element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                            &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &ref) == .success,
              let kids = ref as? [AXUIElement] else { return [] }
        return kids
    }

    /// Find and press the first leaf menu item whose title contains every needle
    /// (case-insensitive) — e.g. ["new","window"] hits "New Window" and Finder's
    /// "New Finder Window", while skipping containers like "New Window with…"
    /// that only open a submenu. Returns whether a press was performed.
    private static func pressMenuItem(pid: pid_t, titleNeedles needles: [String]) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString,
                                            &barRef) == .success, let bar = barRef else { return false }
        return pressMatch(in: bar as! AXUIElement, needles: needles, depth: 0)
    }

    private static func pressMatch(in element: AXUIElement, needles: [String], depth: Int) -> Bool {
        guard depth <= 6 else { return false }
        for child in children(of: element) {
            let title = titleOf(child).lowercased()
            let isLeafItem = roleOf(child) == (kAXMenuItemRole as String)
                && !children(of: child).contains { roleOf($0) == (kAXMenuRole as String) }
            if isLeafItem, needles.allSatisfy({ title.contains($0) }),
               AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                return true
            }
            if pressMatch(in: child, needles: needles, depth: depth + 1) { return true }
        }
        return false
    }

    /// Fallback for apps whose "New Window" item we couldn't find by title:
    /// post ⌘N to the (just-activated) frontmost app. virtualKey 45 == 'n'.
    private static func synthesizeCommandN() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

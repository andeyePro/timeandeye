import Foundation
import AppKit
import ApplicationServices
import AmbitickCore

/// Dev diagnostic for the "sender as a signal" work (TODO 2026-06-29). Walks the
/// focused window's Accessibility tree of the frontmost browser and reports the
/// email-like strings it finds, with each node's role/context, so we can see what
/// is robustly extractable before committing a real sender extractor.
///
/// This is a PROBE, not the feature: it crawls the whole (bounded) tree, which is
/// exactly what the shipped version must NOT do on the hot path. It runs only on
/// an explicit button press.
public enum EmailSignalProbe {
    public struct Result {
        public let app: String
        public let nodesScanned: Int
        public let truncated: Bool
        /// Distinct email addresses anywhere in the tree, first-seen order.
        public let candidates: [String]
        /// `role | text` for each node whose text contains '@' (capped).
        public let contexts: [String]
    }

    /// Browsers we know how to target. AX can read any of these by pid even when
    /// Ambitick itself is frontmost (so the diagnostic button works).
    public static let browserBundleIDs = [
        "com.google.Chrome", "com.operasoftware.Opera",
        "com.brave.Browser", "com.apple.Safari",
    ]

    private static let maxNodes = 8000
    private static let maxDepth = 45

    public static func probeFrontBrowser() -> Result? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = targetBrowser() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        // Chromium browsers (and Electron apps) keep their renderer accessibility
        // tree OFF until an assistive technology asks for it — so the web page is
        // invisible to AX and only the window chrome shows. Setting
        // AXManualAccessibility on the app element is the documented opt-in; Chrome
        // then builds the page tree (asynchronously, hence the retry below).
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        func snapshot() -> (count: Int, texts: [String], contexts: [String])? {
            var win: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
                  let window = win else { return nil }
            var texts: [String] = []
            var contexts: [String] = []
            var count = 0
            // swiftlint:disable:next force_cast
            walk(window as! AXUIElement, depth: 0, count: &count, texts: &texts, contexts: &contexts)
            return (count, texts, contexts)
        }

        // First pass; if it's only chrome (tree not built yet), wait briefly and
        // retry once so it's usually a single click.
        var snap = snapshot()
        if (snap?.count ?? 0) < 200 {
            usleep(600_000)
            snap = snapshot() ?? snap
        }
        guard let s = snap else {
            return Result(app: app.localizedName ?? "?", nodesScanned: 0,
                          truncated: false, candidates: [], contexts: [])
        }
        let blob = s.texts.joined(separator: "\n")
        return Result(app: app.localizedName ?? "?",
                      nodesScanned: s.count,
                      truncated: s.count >= maxNodes,
                      candidates: EmailSignal.addresses(in: blob),
                      contexts: Array(s.contexts.prefix(60)))
    }

    /// AppleScript app name for a Chromium-family bundle id (the JS probe channel).
    private static func chromeAppName(_ bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome": return "Google Chrome"
        case "com.operasoftware.Opera": return "Opera"
        case "com.brave.Browser": return "Brave Browser"
        default: return nil
        }
    }

    /// The robust browser channel: run a tiny read-only JS snippet in the active
    /// tab via Apple Events (same pipe as the URL read) and dump the sender /
    /// recipient spans the page exposes. Needs Chrome ▸ View ▸ Developer ▸ "Allow
    /// JavaScript from Apple Events" (off by default).
    public static func chromeDOMProbe() -> String {
        guard let app = targetBrowser(),
              let bid = app.bundleIdentifier, let appName = chromeAppName(bid) else {
            return "JS probe: front browser is not Chromium (Chrome/Opera/Brave)."
        }
        // Single-quoted JS + String.fromCharCode(10) for newlines, no backslashes
        // → nothing to escape through AppleScript. A blanket [email] query is
        // polluted by the inbox-list rows (.yP), which Gmail keeps in the DOM with
        // a thread open. So probe SEVERAL scoped selectors and report each, to find
        // the one that isolates the OPEN conversation's sender (likely .gD /
        // data-hovercard-id) vs recipients (.g2) vs the list (.yP).
        let js = "(function(){var L=String.fromCharCode(10);"
            + "function d(sel){var a=[];document.querySelectorAll(sel).forEach(function(e){"
            + "var em=e.getAttribute('email')||e.getAttribute('data-hovercard-id')||'';"
            + "var nm=(e.getAttribute('name')||e.textContent||'').trim().slice(0,28);"
            + "a.push(nm+' <'+em+'>');});return sel+' ['+a.length+']: '+a.slice(0,6).join(' || ');}"
            + "try{return 'hash: '+location.hash+L+'TITLE: '+document.title+L"
            + "+d('.gD')+L+d('.g2')+L+d('[data-hovercard-id]')+L"
            + "+'.yP(list) count: '+document.querySelectorAll('.yP').length;}"
            + "catch(err){return 'JSERR '+err;}})()"
        let source = "tell application \"\(appName)\" to execute active tab of front window javascript \"\(js)\""
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "\(error)"
            return "JS probe error: \(msg)\n" +
                   "(If it says JavaScript is off: Chrome ▸ View ▸ Developer ▸ " +
                   "Allow JavaScript from Apple Events.)"
        }
        return result?.stringValue ?? "JS probe: empty result."
    }

    private static func targetBrowser() -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let active = running.first(where: {
            $0.isActive && browserBundleIDs.contains($0.bundleIdentifier ?? "")
        }) { return active }
        return running.first {
            browserBundleIDs.contains($0.bundleIdentifier ?? "") && !$0.isTerminated
        }
    }

    private static func walk(_ el: AXUIElement, depth: Int, count: inout Int,
                             texts: inout [String], contexts: inout [String]) {
        if count >= maxNodes || depth > maxDepth { return }
        count += 1
        for attr in [kAXValueAttribute, kAXTitleAttribute,
                     kAXDescriptionAttribute, kAXHelpAttribute] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
                  let s = v as? String, !s.isEmpty else { continue }
            texts.append(s)
            if s.contains("@") {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                let r = (role as? String) ?? "?"
                let oneLine = s.replacingOccurrences(of: "\n", with: " ")
                let clipped = oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
                contexts.append("\(r) | \(clipped)")
            }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
           let kids = children as? [AXUIElement] {
            for k in kids {
                walk(k, depth: depth + 1, count: &count, texts: &texts, contexts: &contexts)
            }
        }
    }
}

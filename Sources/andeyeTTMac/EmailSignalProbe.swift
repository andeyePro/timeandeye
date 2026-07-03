import Foundation
import AppKit
import ApplicationServices
import andeyeTTCore

/// Dev diagnostic for the "sender as a signal" work (TODO 2026-06-29). Walks the
/// focused window's Accessibility tree of the frontmost browser and reports the
/// email-like strings it finds, with each node's role/context, so we can see what
/// is robustly extractable before committing a real sender extractor.
///
/// This is a PROBE, not the feature: it crawls the whole (bounded) tree, which is
/// exactly what the shipped version must NOT do on the hot path. It runs only on
/// an explicit button press. The shipped feature is `EmailCaptureEngine`
/// (async, deadline-bounded, one-in-flight) — `buildReport()` below reuses its
/// safe `osascript` channel so the diagnostics button no longer risks the
/// 2026-06-30 main-thread freeze either.
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
    /// andeye itself is frontmost (so the diagnostic button works).
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

    /// Full diagnostics report: the AX-tree crawl plus the real recipe channel
    /// (system detect + sender/recipient DOM read), the latter now run through
    /// `EmailCaptureEngine`'s deadline-bounded `osascript` subprocess instead
    /// of the main-thread-bound `NSAppleScript` this probe used until
    /// 2026-07-03 — the diagnostics button shares the same safe engine as
    /// live capture. Callers on the main thread must still hop to a
    /// background queue first (this blocks up to the engine's deadline).
    public static func buildReport() -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibility permission not granted — System Settings ▸ Privacy ▸ Accessibility."
        }
        guard let r = probeFrontBrowser() else {
            return "No running browser found (Chrome / Opera / Brave / Safari)."
        }
        var out = "Browser: \(r.app)\nNodes scanned: \(r.nodesScanned)\(r.truncated ? " (capped)" : "")\n"
        if r.nodesScanned < 200 {
            out += "(Looks like only the window chrome — Chrome's page accessibility " +
                   "tree may still be building. Click Probe again in a second.)\n"
        }
        out += "\nEmail addresses found (\(r.candidates.count)):\n"
        out += r.candidates.isEmpty ? "  (none)\n"
            : r.candidates.map { "  • \($0)" }.joined(separator: "\n") + "\n"
        out += "\nNodes containing '@' (role | text):\n"
        out += r.contexts.isEmpty ? "  (none)"
            : r.contexts.map { "  \($0)" }.joined(separator: "\n")
        out += "\n\n— Recipe channel (page JavaScript) —\n"
        if let bid = targetBrowser()?.bundleIdentifier,
           let appName = EmailCaptureEngine.chromeAppName(bundleID: bid) {
            if let p = EmailCaptureEngine.captureNow(appName: appName) {
                out += "System: \(p.system.rawValue)\n"
                if let e = p.error { out += "Error: \(e)\n" }
                func fmt(_ ps: [EmailSignal.Party]) -> String {
                    ps.isEmpty ? "(none)" : ps.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ")
                }
                out += "Sender: \(fmt(p.senders))\n"
                out += "Recipients: \(fmt(p.recipients))\n"
                let others = EmailSignal.counterparties(senders: p.senders, recipients: p.recipients)
                out += "Counterparties (you removed): \(fmt(others))\n"
                let domains = Set(others.compactMap { EmailSignal.domain(of: $0.email) })
                    .sorted().joined(separator: ", ")
                out += "Counterparty domains: \(domains.isEmpty ? "(none)" : domains)"
            } else {
                out += "Capture failed unexpectedly."
            }
        } else {
            out += "Front app is not a supported browser."
        }
        return out
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

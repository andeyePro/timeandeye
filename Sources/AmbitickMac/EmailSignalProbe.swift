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
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else {
            return Result(app: app.localizedName ?? "?", nodesScanned: 0,
                          truncated: false, candidates: [], contexts: [])
        }
        var texts: [String] = []
        var contexts: [String] = []
        var count = 0
        // swiftlint:disable:next force_cast
        walk(window as! AXUIElement, depth: 0, count: &count, texts: &texts, contexts: &contexts)
        let blob = texts.joined(separator: "\n")
        return Result(app: app.localizedName ?? "?",
                      nodesScanned: count,
                      truncated: count >= maxNodes,
                      candidates: EmailSignal.addresses(in: blob),
                      contexts: Array(contexts.prefix(60)))
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

import Foundation

/// A user-pinned association: "this surface is ALWAYS this task" at 100 %
/// certainty, overriding the ranker, learning and soft primes (everything
/// unpinned caps at 0.95). Unlike a soft prime — which keys on the exact
/// surface — a pin keys on a CHOSEN SCOPE: a broad→narrow PREFIX of the
/// surface's identity, so one pin can cover a whole site, a section of a
/// site, a single page, a whole app, or one window of an app.
///
/// Identity segments, broad→narrow, always start with the "root":
///   url:  ["github.com", "andeyePro", "andeyeTT", "issues", "42"]   (host + path)
///   app:  ["Visual Studio Code", "andeyeTT", "Attributor.swift"] (app + title parts)
/// A pin stores the selected prefix; it matches any surface whose identity
/// begins with that prefix.
public struct PinScope: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case url, app }
    public var kind: Kind
    /// The selected prefix (length ≥ 1), broad→narrow.
    public var prefix: [String]

    public init(kind: Kind, prefix: [String]) {
        self.kind = kind
        self.prefix = prefix
    }

    /// The full broad→narrow identity of a signal, or nil if there's nothing
    /// to pin (no app at all). The first element is the root (host / app name).
    public static func identity(of signal: ActivitySignal) -> (kind: Kind, segments: [String])? {
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            return (.url, [host] + path)
        }
        guard !signal.app.isEmpty else { return nil }
        return (.app, [signal.app] + titleSegments(signal.windowTitle))
    }

    /// The prefix length this pin editor should select by default — the
    /// "intelligent" blue selection the user then widens/narrows.
    ///  • url: host + first path segment (e.g. github.com/andeyePro) — the usual
    ///    "this section is this task" grain; host-only when there's no path.
    ///  • app: app + the first window-title segment when there is one (e.g. a
    ///    named Ghostty/terminal window or a doc title) — most users run several
    ///    windows of one app on different tasks, so the window is the useful
    ///    grain. Widen to app-only with ←. App-only when there is no title.
    public static func defaultPrefixCount(kind: Kind, segments: [String]) -> Int {
        switch kind {
        case .url: return min(2, segments.count)
        case .app: return min(2, segments.count)
        }
    }

    /// Does this pin cover the given signal?
    ///  • url: identity must START WITH the pinned prefix — host/path is
    ///    structurally stable, so the broad→narrow prefix is reliable.
    ///  • app: the app must match and every pinned title segment must be
    ///    PRESENT (in any position). App/window titles are volatile in ORDER —
    ///    a terminal prepends its mode ("nvim — project", "~/dir — fish"), so a
    ///    window-name pinned at position 1 slides to position 2 and a strict
    ///    positional prefix would silently stop matching. Presence-matching
    ///    keeps a window-name pin working as the leading title text changes.
    public func matches(_ signal: ActivitySignal) -> Bool {
        guard let id = Self.identity(of: signal), id.kind == kind,
              let root = id.segments.first, let pinnedRoot = prefix.first else { return false }
        // Case-insensitive segment comparison (reviewer B14): every PinOp is
        // case-insensitive, but scopes compared raw — an app retitling
        // "Andeye" → "andeye" silently unpinned while the expression path
        // still matched.
        func eq(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: .caseInsensitive) == .orderedSame
        }
        switch kind {
        case .url:
            guard id.segments.count >= prefix.count else { return false }
            return zip(id.segments.prefix(prefix.count), prefix).allSatisfy(eq)
        case .app:
            guard eq(root, pinnedRoot) else { return false }
            let titleSegments = id.segments.dropFirst()
            return prefix.dropFirst().allSatisfy { p in titleSegments.contains { eq($0, p) } }
        }
    }

    /// Split a window title into identity parts on the separators apps use
    /// (en/em dash, pipe, slash, " - "), trimmed, empties dropped.
    public static func titleSegments(_ title: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        var parts = [title]
        for sep in [" — ", " – ", " | ", " - ", " / ", "/"] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Display separator between identity segments for each kind.
    public static func separator(for kind: Kind) -> String {
        kind == .url ? "/" : "  ▸  "
    }
}

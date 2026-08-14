import Foundation

/// The window-detail "similar" ladder (Martin, 2026-07-07: a repeatable
/// [+similar] that accumulates windows like the current one, with a paired
/// [-similar] to step back over-pressing). Three rungs, each a strict
/// superset of the one before:
///
///   exact     — app + title + URL (the "+ all" twins)
///   appTitle  — same app + title, any URL (every video on the same page
///               family, every chat behind one window title)
///   app       — everything recorded from the same app
///
/// Pure key derivation so the rung semantics are Linux-checkable; the
/// timeline owns selection state and applies set unions/subtractions.
package enum SpanSimilarity {
    package enum Level: Int, CaseIterable, Comparable, Sendable {
        case exact = 0
        case appTitle = 1
        case app = 2

        package static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// The grouping key for `signal` at `level`. Two spans are "similar at
    /// `level`" iff their keys match.
    package static func key(_ signal: ActivitySignal, at level: Level) -> String {
        switch level {
        case .exact:
            return "\(signal.app)|\(signal.windowTitle ?? "")|\(signal.tabURL ?? "")"
        case .appTitle:
            return "\(signal.app)|\(signal.windowTitle ?? "")"
        case .app:
            return signal.app
        }
    }
}

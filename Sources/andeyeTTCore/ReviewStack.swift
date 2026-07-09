import Foundation

/// One collapsed drawer row: every pending `ReviewSegment` on the same
/// surface (app|windowTitle|tabURL — the identical key `teachingSignals(for:)`
/// already groups on in Models.swift), presented as ONE decision instead of
/// N (approvals-drawer spec, Martin's stack-by-default choice: "1,040 items"
/// only ever meant a much smaller number of distinct surfaces).
public struct ReviewStack: Equatable, Sendable, Identifiable {
    /// The stacked segments, in queue order (oldest first, matching
    /// `pendingReview()`'s own order).
    public var segments: [ReviewSegment]
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    /// Summed segment durations — the group's total pending time.
    public var total: TimeInterval
    /// Earliest segment start in the group.
    public var first: Date
    /// Latest segment end in the group — what stacks sort newest-first by.
    public var last: Date

    /// The surface key — stable identity for SwiftUI's ForEach/List.
    public var id: String { "\(app)|\(windowTitle ?? "")|\(tabURL ?? "")" }

    public init(segments: [ReviewSegment], app: String, windowTitle: String?, tabURL: String?,
                total: TimeInterval, first: Date, last: Date) {
        self.segments = segments
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.total = total
        self.first = first
        self.last = last
    }
}

public extension Array where Element == ReviewSegment {
    /// Group pending segments into stacks by identical surface, newest stack
    /// first (by each stack's most recent segment) — the drawer's default
    /// shape. Segments within a stack keep their original (queue) order.
    func stacked() -> [ReviewStack] {
        var order: [String] = []
        var groups: [String: [ReviewSegment]] = [:]
        for segment in self {
            let key = "\(segment.app)|\(segment.windowTitle ?? "")|\(segment.tabURL ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(segment)
        }
        let stacks: [ReviewStack] = order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            let starts = group.map(\.start)
            let ends = group.map(\.end)
            let total = group.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            return ReviewStack(segments: group, app: first.app, windowTitle: first.windowTitle,
                               tabURL: first.tabURL, total: total,
                               first: starts.min() ?? first.start, last: ends.max() ?? first.end)
        }
        return stacks.sorted { $0.last > $1.last }
    }
}

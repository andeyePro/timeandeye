import Foundation

/// One collapsed drawer row: every pending `ReviewSegment` on the same
/// surface (app|windowTitle|tabURL — the identical key `teachingSignals(for:)`
/// already groups on in Models.swift), presented as ONE decision instead of
/// N (approvals-drawer spec, Martin's stack-by-default choice: "1,040 items"
/// only ever meant a much smaller number of distinct surfaces).
package struct ReviewStack: Equatable, Sendable, Identifiable {
    /// The stacked segments, in queue order (oldest first, matching
    /// `pendingReview()`'s own order).
    package var segments: [ReviewSegment]
    package var app: String
    package var windowTitle: String?
    package var tabURL: String?
    /// Summed segment durations — the group's total pending time.
    package var total: TimeInterval
    /// Earliest segment start in the group.
    package var first: Date
    /// Latest segment end in the group — what stacks sort newest-first by.
    package var last: Date

    /// The surface key — stable identity for SwiftUI's ForEach/List.
    package var id: String { "\(app)|\(windowTitle ?? "")|\(tabURL ?? "")" }

    package init(segments: [ReviewSegment], app: String, windowTitle: String?, tabURL: String?,
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

package extension Array where Element == ReviewSegment {
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

    /// Review-queue admission floor: keep only segments that are themselves
    /// at least `floor` seconds long. Per-SEGMENT deliberately (Martin,
    /// 2026-07-09, overturning the same-day per-surface pooling): a visit
    /// shorter than the switch grace never becomes a tracked switch, so its
    /// identity is never worth a human decision — "even if we visited it
    /// 1,000,000 times". Contiguous same-surface time is already ONE segment
    /// by the time it reaches the queue (`queueReview` extends the pending
    /// segment), so a genuine long visit still qualifies whole; only
    /// NON-contiguous brief glances vanish. Filtered-out segments stay
    /// journalled and on the timeline exactly as before — the floor thins
    /// the queue, never the record. A floor of 0 (or below) admits all.
    func meetingReviewFloor(_ floor: TimeInterval) -> [ReviewSegment] {
        guard floor > 0 else { return self }
        return filter { $0.end.timeIntervalSince($0.start) >= floor }
    }
}

/// One row of the drawer as the eye sees it, in flattened display order:
/// a GROUP row (a stack's header, or the strip down its left edge) or one
/// slice inside an expanded group. Selection gestures speak in rows; the
/// selection itself stays a flat set of slice ids — a group row simply
/// stands for every slice in its stack.
package enum ReviewRow: Hashable, Sendable {
    case stack(String)
    case slice(UUID)
}

/// The drawer's selection, with the standard macOS semantics (Martin,
/// 2026-07-10, second pass: "Can we have the macOS default: single click
/// changes selection, shift click spans, cmd click toggles"): a plain
/// click REPLACES the selection with the clicked row; ⌘-click TOGGLES the
/// row in or out without disturbing the rest; ⇧-click SPANS from the
/// anchor — the most recent NON-shift click — through the clicked row in
/// the flattened visible row order, so a span across group headers picks
/// up the whole groups and slices in between. NSTableView's anchor rules:
/// successive shift-clicks RE-span from the same anchor (they never
/// accumulate), and the selection that existed when the anchor was set
/// survives underneath a span. A group row stands for all of its slices,
/// so a stack reads selected exactly when every one of its slices is, a
/// selection freely mixes lone slices with whole groups, and the assign
/// bar's certainty aggregates over the SAME per-slice list either way.
/// Pure value semantics so the CLT-only loop can check it; the drawer
/// just renders membership.
package struct ReviewSelection: Equatable, Sendable {
    /// The selected slice ids — all the view highlights, all the bar scopes.
    package private(set) var selected: Set<UUID> = []
    /// The span anchor: the row of the most recent plain or ⌘ click.
    package private(set) var anchor: ReviewRow?
    /// The selection as it stood when the anchor was set — what every
    /// ⇧-span from that anchor builds ON, so a second shift-click re-spans
    /// (dropping the first span's extras) instead of accumulating.
    private var anchorBase: Set<UUID> = []

    package init() {}

    /// The slice ids a row stands for: itself, or its stack's whole group.
    package static func ids(of row: ReviewRow, in stacks: [ReviewStack]) -> Set<UUID> {
        switch row {
        case .slice(let id): return [id]
        case .stack(let key):
            guard let stack = stacks.first(where: { $0.id == key }) else { return [] }
            return Set(stack.segments.map(\.id))
        }
    }

    /// Plain click: the clicked row becomes the selection (and the anchor).
    package mutating func click(_ row: ReviewRow, in stacks: [ReviewStack]) {
        selected = Self.ids(of: row, in: stacks)
        anchor = row
        anchorBase = selected
    }

    /// ⌘-click: toggle the row in or out. A group that is only PARTLY
    /// selected completes (a group click means "all of this"); only a
    /// fully-selected group toggles out. The row becomes the anchor.
    package mutating func commandClick(_ row: ReviewRow, in stacks: [ReviewStack]) {
        let ids = Self.ids(of: row, in: stacks)
        if !ids.isEmpty, ids.isSubset(of: selected) {
            selected.subtract(ids)
        } else {
            selected.formUnion(ids)
        }
        anchor = row
        anchorBase = selected
    }

    /// ⇧-click: select everything between the anchor and the clicked row —
    /// inclusive, either direction — in `rows`, the drawer's CURRENT
    /// flattened visible order (sort first, then span). The anchor stays
    /// put, so the next shift-click re-spans from the same place. No
    /// anchor yet (first click of a session), or an anchor row no longer
    /// on display (assigned away, or its stack collapsed), degrades to a
    /// plain click on the target — never a guess.
    package mutating func shiftClick(_ row: ReviewRow, rows: [ReviewRow],
                                    in stacks: [ReviewStack]) {
        guard let ti = rows.firstIndex(of: row) else { return }
        guard let anchor, let ai = rows.firstIndex(of: anchor) else {
            click(row, in: stacks)
            return
        }
        let lo = Swift.min(ai, ti), hi = Swift.max(ai, ti)
        var span = Set<UUID>()
        for r in rows[lo...hi] { span.formUnion(Self.ids(of: r, in: stacks)) }
        selected = anchorBase.union(span)
    }

    /// Drop ids of slices assigned away meanwhile, so counts and certainty
    /// aggregates recalculate over what actually remains.
    package mutating func prune(to stacks: [ReviewStack]) {
        let live = stacks.everySliceID
        selected.formIntersection(live)
        anchorBase.formIntersection(live)
    }

    /// Nothing selected — what an assign leaves behind.
    package mutating func clear() {
        selected = []
        anchor = nil
        anchorBase = []
    }

    /// A stack is selected when EVERY slice in it is — the header and left
    /// margin highlight rides on this, never on separate group state.
    package static func isStackSelected(_ stack: ReviewStack, in selection: Set<UUID>) -> Bool {
        !stack.segments.isEmpty && stack.segments.allSatisfy { selection.contains($0.id) }
    }

    /// The selected slices, enumerated per-slice in queue order — what the
    /// assign bar scopes to and what its certainty means: group-selected
    /// slices land in the SAME list as individually-clicked ones. Reading
    /// through the CURRENT stacks self-prunes ids assigned away meanwhile.
    package static func segments(of selection: Set<UUID>, in stacks: [ReviewStack]) -> [ReviewSegment] {
        stacks.flatMap(\.segments).filter { selection.contains($0.id) }
    }
}

package extension Array where Element == ReviewStack {
    /// Expand-all target state (Martin, 2026-07-10: "Could we have an
    /// open-all option?"): every stack id, so ONE header control can open
    /// the whole drawer rather than the user clicking each chevron.
    var everyStackID: Set<String> { Set(map(\.id)) }

    /// …and every slice id — open-all opens the slice detail disclosures
    /// too, not just the stacks, so "open all" really shows everything.
    var everySliceID: Set<UUID> { Set(flatMap(\.segments).map(\.id)) }

    /// Whether the drawer is already fully open — the header control reads
    /// "Collapse all" when nothing is left to reveal. Subset, not equality:
    /// ids of rows assigned away meanwhile linger harmlessly in the view's
    /// sets and must not stop the control reading the true state. An empty
    /// queue is never "fully expanded" — there is nothing to collapse.
    func isFullyExpanded(stacks: Set<String>, slices: Set<UUID>) -> Bool {
        !isEmpty && everyStackID.isSubset(of: stacks) && everySliceID.isSubset(of: slices)
    }
}

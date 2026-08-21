import Foundation

/// Pure time-geometry for the timeline's interactive editing. UI-independent
/// so the behaviour is checkable.
public enum TimelineMath {
    /// Snap a proposed time to the nearest session edge within tolerance.
    public static func snap(_ time: Date, to sessions: [Session],
                            excluding: UUID? = nil,
                            tolerance: TimeInterval) -> Date {
        var best = time
        var bestDistance = tolerance
        for session in sessions where session.id != excluding {
            for edge in [session.start, session.end] {
                let distance = abs(edge.timeIntervalSince(time))
                if distance < bestDistance {
                    bestDistance = distance
                    best = edge
                }
            }
        }
        return best
    }

    /// Nearest of `edges` within `tolerance`, else `time` unchanged. The
    /// conflict resolver's "Snap to windows" goes through this: unbounded, a
    /// snap can move a boundary so far it lands back on the edge the user
    /// deliberately edited AWAY from, which reads as "the save did nothing"
    /// (Martin, 2026-08-18 — 10:07 silently rewritten to 10:35).
    public static func nearestEdge(to time: Date, in edges: [Date],
                                   tolerance: TimeInterval) -> Date {
        var best = time
        var bestDistance = tolerance
        for edge in edges {
            let distance = abs(edge.timeIntervalSince(time))
            if distance < bestDistance {
                bestDistance = distance
                best = edge
            }
        }
        return best
    }

    /// The free gap around a point: bounded by the neighbouring sessions and
    /// the given range. nil when the point falls inside a session.
    public static func gap(at point: Date, in sessions: [Session],
                           within range: ClosedRange<Date>) -> (start: Date, end: Date)? {
        var lower = range.lowerBound
        var upper = range.upperBound
        for session in sessions {
            if session.start <= point, point < session.end { return nil }
            if session.end <= point { lower = max(lower, session.end) }
            if session.start > point { upper = min(upper, session.start) }
        }
        guard upper.timeIntervalSince(lower) >= 60 else { return nil }
        return (lower, upper)
    }

    public struct Trim: Equatable, Sendable {
        public var session: Session
        public var delete: Bool
        public init(session: Session, delete: Bool) {
            self.session = session
            self.delete = delete
        }
    }

    /// "Eat into them": neighbours overlapped by [start, end) get trimmed to
    /// make room; ones squeezed below a minute are deleted. A neighbour fully
    /// inside the window is deleted.
    public static func trims(for start: Date, _ end: Date,
                             excluding: UUID? = nil,
                             in sessions: [Session]) -> [Trim] {
        var out: [Trim] = []
        for neighbour in sessions where neighbour.id != excluding {
            guard neighbour.end > start, neighbour.start < end else { continue }
            var adjusted = neighbour
            if neighbour.start >= start, neighbour.end <= end {
                out.append(Trim(session: neighbour, delete: true))
                continue
            }
            if neighbour.start < start {
                adjusted.end = start
            } else {
                adjusted.start = end
            }
            out.append(Trim(session: adjusted,
                            delete: adjusted.end.timeIntervalSince(adjusted.start) < 60))
        }
        return out
    }

    /// Split a session: time inside any `reassign` range becomes `target`,
    /// the rest stays on the session's task. Returns the replacement pieces
    /// (new ids). ONLY the selected ranges ever change task — a fragment is
    /// merged into its neighbour only when they share a task, so no unselected
    /// time is ever silently reattributed, even a sub-minute sliver at a
    /// range edge. Pure, so it is unit-checkable.
    public static func split(_ session: Session, reassign ranges: [(start: Date, end: Date)],
                             to target: TaskRef) -> [Session] {
        // Clip + merge the reassign ranges within the session.
        let clipped = ranges
            .map { (max($0.start, session.start), min($0.end, session.end)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        guard !clipped.isEmpty else { return [session] }
        var merged: [(Date, Date)] = []
        for r in clipped {
            if let last = merged.last, r.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, r.1)
            } else {
                merged.append(r)
            }
        }
        // Walk boundaries, tagging each segment target vs original.
        var bounds: [Date] = [session.start]
        for (s, e) in merged { bounds.append(s); bounds.append(e) }
        bounds.append(session.end)
        bounds = Array(Set(bounds)).sorted()
        var pieces: [Session] = []
        for i in 0..<(bounds.count - 1) {
            let s = bounds[i], e = bounds[i + 1]
            guard e > s else { continue }
            let mid = s.addingTimeInterval(e.timeIntervalSince(s) / 2)
            let inReassign = merged.contains { $0.0 <= mid && mid < $0.1 }
            let task = inReassign ? target : session.task
            if var last = pieces.last, last.task == task {
                // same task as the neighbour — merge, no attribution change
                last.end = e
                pieces[pieces.count - 1] = last
            } else {
                // different task — ALWAYS its own piece, even under a minute.
                // The old code absorbed a short different-task fragment into its
                // neighbour, which silently flipped that time to the neighbour's
                // task: it moved unselected time at a range edge AND swallowed a
                // genuinely-selected sub-minute window. An honest short sliver
                // beats misattributing a second of tracked time.
                // Ownership rule (attribution-calculus spec): a reassigned piece
                // moves to `target` by the user's hand, so it carries humanWord
                // (1.0), not the old task's certainty; a non-reassigned piece
                // keeps the session's own certainty.
                pieces.append(Session(task: task, start: s, end: e,
                                      certainty: inReassign ? Attributor.humanWord
                                                            : session.certainty,
                                      comment: session.comment))
            }
        }
        return pieces.isEmpty ? [session] : pieces
    }

    /// Split-and-reassign across a SET of sessions. A displayed block can be
    /// backed by more than one journal row — the live block folds earlier
    /// contiguous same-task slices into one displayed slice, and a coalesce can
    /// lag — so a window selected in the strip may live in a different row than
    /// the one the caller starts from. Split every session; return only those
    /// the ranges actually change (as `(original, pieces)`), so untouched rows —
    /// including a same-task row that merely sits between two selected windows —
    /// are left alone. Pure, so it is unit-checkable.
    public static func splitAcross(_ sessions: [Session],
                                   reassign ranges: [(start: Date, end: Date)],
                                   to target: TaskRef)
        -> [(session: Session, pieces: [Session])] {
        var out: [(session: Session, pieces: [Session])] = []
        for s in sessions {
            let pieces = split(s, reassign: ranges, to: target)
            // A no-op split (ranges miss this row, or don't change its task)
            // returns the row unchanged — skip it, so we neither churn its id
            // nor open an empty undo step.
            guard pieces.count > 1 || pieces.first?.task != s.task else { continue }
            out.append((s, pieces))
        }
        return out
    }

    /// Join comment fragments in the given order: nils/empties dropped, the
    /// rest joined with `CommentRouting.commentSeparator` ("; "). The ONE
    /// joiner shared by `mergeAdjacent`, `foldLive` and the live display
    /// composition, so a comment reads the same wherever its slice ends up.
    public static func joinComments(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: CommentRouting.commentSeparator)
    }

    /// Merge same-task sessions that butt up against each other (end ≈ start,
    /// within `tolerance`) into one, losing no data: the survivor spans both,
    /// keeps the earliest start / latest end, joins comments, blends certainty
    /// by DURATION-WEIGHTED MEAN (spec §Folds: confidence blends by time — not
    /// the min of its parts, not the max), and is flagged for re-push.
    /// Survivor keeps the FIRST id; callers delete the absorbed ids. Pure /
    /// unit-checkable.
    public static func mergeAdjacent(_ sessions: [Session],
                                     tolerance: TimeInterval = 2) -> [Session] {
        let sorted = sessions.sorted { $0.start < $1.start }
        var out: [Session] = []
        for s in sorted {
            if var last = out.last, last.task == s.task,
               abs(s.start.timeIntervalSince(last.end)) <= tolerance {
                // Weight by each part's own duration BEFORE extending the
                // survivor (`last` already spans everything merged so far, so
                // this accumulates the correct running mean over the chain).
                let lastDur = last.end.timeIntervalSince(last.start)
                let sDur = s.end.timeIntervalSince(s.start)
                let total = lastDur + sDur
                last.end = Swift.max(last.end, s.end)
                last.comment = joinComments([last.comment, s.comment])
                last.certainty = total > 0
                    ? (last.certainty * lastDur + s.certainty * sDur) / total
                    : last.certainty
                last.pushedToOP = false
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// The exact-restore bookkeeping for one coalesce pass — everything an
    /// undo needs to put the journal back byte-for-byte: the absorbed
    /// originals (deleted rows, exact prior state) and each surviving row's
    /// prior/merged pair. Pure so "undoing a merge restores the exact prior
    /// rows" is checkable without a journal or a controller (the trigger
    /// incident: a save fused two slices OUTSIDE the edit's undo group and
    /// ⌘Z then operated on the fused row instead of restoring the originals).
    public struct CoalescePlan: Equatable, Sendable {
        public struct Rewrite: Equatable, Sendable {
            /// The survivor as it stood before the merge.
            public var prior: Session
            /// The survivor as the merge leaves it (same id, wider extent).
            public var merged: Session
            public init(prior: Session, merged: Session) {
                self.prior = prior; self.merged = merged
            }
        }
        /// Absorbed originals — rows the merge deletes, in their exact prior
        /// state. Restoring them (callers clear remote linkage first when the
        /// merge deleted their backend entries) plus every rewrite's `prior`
        /// reconstructs the pre-merge journal exactly.
        public var removed: [Session]
        public var rewrites: [Rewrite]
        public var isEmpty: Bool { removed.isEmpty && rewrites.isEmpty }
        public init(removed: [Session], rewrites: [Rewrite]) {
            self.removed = removed; self.rewrites = rewrites
        }
    }

    /// Diff a `mergeAdjacent` result against its input: which rows the merge
    /// deletes and which it rewrites — the compensating-undo plan.
    public static func coalescePlan(original: [Session], merged: [Session]) -> CoalescePlan {
        let survivors = Set(merged.map(\.id))
        let removed = original.filter { !survivors.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        let rewrites: [CoalescePlan.Rewrite] = merged.compactMap { m in
            guard let prior = byID[m.id], prior != m else { return nil }
            return CoalescePlan.Rewrite(prior: prior, merged: m)
        }
        return CoalescePlan(removed: removed, rewrites: rewrites)
    }

    /// The displayed live block's fold. The journal only coalesces on flush,
    /// so while tracking, journalled same-task slices can butt up against the
    /// live start; the timeline shows them and the live clock as ONE slice.
    /// Walks back over contiguous (gap ≤ `tolerance`) same-task rows, removing
    /// them and extending the start over them — and carries their stored
    /// comments, joined oldest-first, so folding a commented row under the
    /// live block never hides its comment from the display.
    public struct LiveFold: Equatable, Sendable {
        /// The live block's extended start (earliest folded row's start).
        public var start: Date
        /// The input rows minus the folded ones — what still draws separately.
        public var remaining: [Session]
        /// The folded rows' stored comments, joined oldest-first; nil when
        /// none of them carried one.
        public var foldedComment: String?
        public init(start: Date, remaining: [Session], foldedComment: String?) {
            self.start = start; self.remaining = remaining; self.foldedComment = foldedComment
        }
    }

    public static func foldLive(_ sessions: [Session], task: TaskRef,
                                liveStart: Date,
                                tolerance: TimeInterval = 2) -> LiveFold {
        var list = sessions
        var start = liveStart
        var folded: [Session] = []
        // Repeated first-match walk (not a single pass): each fold moves the
        // start earlier, which can bring the NEXT row into contiguity.
        while let i = list.firstIndex(where: {
            $0.task == task && $0.start < start
                && abs($0.end.timeIntervalSince(start)) <= tolerance }) {
            start = Swift.min(start, list[i].start)
            folded.append(list[i])
            list.remove(at: i)
        }
        folded.sort { $0.start < $1.start }
        return LiveFold(start: start, remaining: list,
                        foldedComment: joinComments(folded.map(\.comment)))
    }

    /// Result of a keyboard move over the slice bar: the range anchor, the
    /// moving focus cursor, and the resulting selection set.
    public struct TimelineKeyNav: Equatable {
        public var anchor: UUID?
        public var focus: UUID?
        public var selection: Set<UUID>
        public init(anchor: UUID?, focus: UUID?, selection: Set<UUID>) {
            self.anchor = anchor; self.focus = focus; self.selection = selection
        }
    }

    /// Keyboard navigation over the slice bar. `ids` is the selectable slices in
    /// start-time order (the caller excludes the live slice, matching the
    /// mouse-selection rules). `anchor` is the shift-range anchor and `focus`
    /// the moving cursor.
    /// - Plain move (`extend == false`): land on the first/last slice when
    ///   nothing is focused yet, else step one neighbour (clamped at the ends);
    ///   the selection becomes just the focused slice and the anchor follows it.
    /// - Extend move (`extend == true`): keep the anchor fixed (seeded from the
    ///   current focus if absent), step the focus one neighbour, and select the
    ///   inclusive anchor…focus range — same shape as a shift-click.
    /// Returns nil when there is nothing selectable.
    public static func keyboardMove(in ids: [UUID], anchor: UUID?, focus: UUID?,
                                    forward: Bool, extend: Bool) -> TimelineKeyNav? {
        guard !ids.isEmpty else { return nil }
        let step = forward ? 1 : -1
        let current = focus ?? anchor
        if extend {
            // Anchor stays put for the whole shift-drag; seed it on first use.
            let anchorID = anchor ?? current ?? (forward ? ids.first : ids.last)
            guard let anchorID, let ai = ids.firstIndex(of: anchorID) else { return nil }
            let fromFocus = focus ?? anchorID
            let fi = ids.firstIndex(of: fromFocus) ?? ai
            let ni = min(max(fi + step, 0), ids.count - 1)
            let newFocus = ids[ni]
            let lo = min(ai, ni), hi = max(ai, ni)
            return TimelineKeyNav(anchor: anchorID, focus: newFocus,
                                  selection: Set(ids[lo...hi]))
        }
        // Plain move: first arrow lands on an end; subsequent arrows step + clamp.
        let ni: Int
        if let current, let ci = ids.firstIndex(of: current) {
            ni = min(max(ci + step, 0), ids.count - 1)
        } else {
            ni = forward ? 0 : ids.count - 1
        }
        let newFocus = ids[ni]
        return TimelineKeyNav(anchor: newFocus, focus: newFocus, selection: [newFocus])
    }

    /// Clamp a viewport to `bounds` (the phone timeline pans within one day
    /// the way the Mac one pans within the history floor…live edge). The span
    /// is clamped to [minSpan, bounds length] first, then the start is slid so
    /// the window never leaves the bounds. Pure, so it is unit-checkable.
    public static func clampViewport(start: Date, span: TimeInterval,
                                     bounds: ClosedRange<Date>,
                                     minSpan: TimeInterval = 300) -> (start: Date, span: TimeInterval) {
        let maxSpan = bounds.upperBound.timeIntervalSince(bounds.lowerBound)
        let s = min(max(span, min(minSpan, maxSpan)), maxSpan)
        var st = max(start, bounds.lowerBound)
        if st.addingTimeInterval(s) > bounds.upperBound {
            st = bounds.upperBound.addingTimeInterval(-s)
        }
        return (st, s)
    }

    /// The tick interval for a time axis: the smallest "round" step whose
    /// on-screen gap is at least `minGap` points, so labels never collide at
    /// any zoom (the Mac picks by span alone; the phone is much narrower).
    public static func tickStep(span: TimeInterval, width: Double,
                                minGap: Double = 44) -> TimeInterval {
        let steps: [TimeInterval] = [300, 900, 1800, 3600, 2 * 3600, 3 * 3600,
                                     6 * 3600, 12 * 3600]
        guard span > 0, width > 0 else { return steps.last! }
        for step in steps where width * step / span >= minGap { return step }
        return steps.last!
    }

    /// The most recent block of sessions separated by gaps < maxGap.
    public static func latestBlock(in sessions: [Session],
                                   maxGap: TimeInterval = 3600) -> (start: Date, end: Date)? {
        let ordered = sessions.sorted { $0.start < $1.start }
        guard var start = ordered.last?.start, var end = ordered.last?.end else { return nil }
        for session in ordered.reversed().dropFirst() {
            if start.timeIntervalSince(session.end) < maxGap {
                start = min(start, session.start)
                end = max(end, session.end)   // a long slice can outlast later-started ones (C19)
            } else {
                break
            }
        }
        return (start, end)
    }
}

/// Plan for the timeline's span-select "Allocate" action (drag/shift-click a
/// TIME RANGE on the bar, not bound to any one slice's edges, then point it at
/// a task). Unlike `splitAndReassign`'s single-task `sessions` filter, a span
/// selection can cross sessions on DIFFERENT tasks, so the plan is computed
/// per session independently. Pure / unit-checkable; the controller applies
/// each action through the existing reassign/split+replace paths so pushed
/// sessions, undo and teaching all go through the one already-checked route.
package enum SpanAllocation {
    /// One session's fate under the plan.
    package enum Action: Equatable, Sendable {
        /// Wholly inside the range: the ORIGINAL (untouched) session, still
        /// on its old task — the caller re-points it whole via the same
        /// `reassignTimelineSessions` path a manual reassign uses, which
        /// mutates the task itself and needs the pre-change value intact for
        /// its own undo bookkeeping.
        case repoint(Session)
        /// Straddles a range edge: replace the original with its split
        /// pieces, mirroring the detail strip's existing split-and-replace
        /// path (delete the original, create each piece fresh).
        case split(original: Session, pieces: [Session])
    }

    /// `sessions`: every session overlapping the range, any task. Sessions
    /// the range doesn't touch, or a fully-inside session already on
    /// `target`, are simply absent from the plan — untouched either way.
    /// Pushed sessions and the Unknown sentinel target get no special
    /// treatment here: that policy (quietly re-queue the OP push; never
    /// teach the attributor) lives in the controller's apply path, not in
    /// this planning step.
    package static func plan(sessions: [Session], range: (start: Date, end: Date),
                           to target: TaskRef) -> [Action] {
        var out: [Action] = []
        for session in sessions {
            guard session.end > range.start, session.start < range.end else { continue }
            if session.start >= range.start, session.end <= range.end {
                guard session.task != target else { continue }
                out.append(.repoint(session))
            } else {
                let pieces = TimelineMath.split(session, reassign: [range], to: target)
                guard pieces.count > 1 || pieces.first?.task != session.task else { continue }
                out.append(.split(original: session, pieces: pieces))
            }
        }
        return out
    }
}

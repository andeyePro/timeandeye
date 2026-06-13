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
    /// (new ids, ≥ minPiece each — shorter fragments merge into the previous
    /// piece). Pure, so it is unit-checkable.
    public static func split(_ session: Session, reassign ranges: [(start: Date, end: Date)],
                             to target: TaskRef, minPiece: TimeInterval = 60) -> [Session] {
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
                last.end = e
                pieces[pieces.count - 1] = last
            } else if let last = pieces.last,
                      e.timeIntervalSince(s) < minPiece {
                // tiny fragment: absorb into the previous piece's time
                pieces[pieces.count - 1].end = e
                _ = last
            } else {
                pieces.append(Session(task: task, start: s, end: e,
                                      certainty: session.certainty, comment: session.comment))
            }
        }
        return pieces.isEmpty ? [session] : pieces
    }

    /// The most recent block of sessions separated by gaps < maxGap.
    public static func latestBlock(in sessions: [Session],
                                   maxGap: TimeInterval = 3600) -> (start: Date, end: Date)? {
        let ordered = sessions.sorted { $0.start < $1.start }
        guard var start = ordered.last?.start, let end = ordered.last?.end else { return nil }
        for session in ordered.reversed().dropFirst() {
            if start.timeIntervalSince(session.end) < maxGap {
                start = min(start, session.start)
            } else {
                break
            }
        }
        return (start, end)
    }
}

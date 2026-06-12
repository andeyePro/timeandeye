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

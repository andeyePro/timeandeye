import Foundation

// Per-slice detail for the review drawer (Martin, 2026-07-10: "Clicking on
// an entry should reveal 100% of the data you have on it … including what
// was tracked before and after"). Pure so the CLT-only loop can check the
// date classification and the neighbour lookup off-Mac; the drawer just
// formats what these return.

/// Which calendar day a moment falls on, relative to now — the drawer's
/// rows carry dates ("Oldest" sorting makes no sense without them), and
/// Today/Yesterday read faster than a numeric date where they apply.
public enum RelativeDay: Equatable, Sendable {
    case today
    case yesterday
    /// Any other day — the UI shows the calendar date itself.
    case other

    /// Classification is by CALENDAR day, not elapsed time: 23:50 last
    /// night is "Yesterday" even from 00:30, and 09:00 this morning is
    /// "Today" even fourteen hours later.
    public static func of(_ date: Date, now: Date = Date(),
                          calendar: Calendar = .current) -> RelativeDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .other
    }
}

/// What the journal tracked immediately before and after a review slice —
/// read-only context for the slice's detail disclosure, with an explicit
/// gap when the neighbour wasn't back-to-back ("…2h gap"). Neighbours are
/// SESSIONS (attributed, tracked time); sessions overlapping the slice
/// itself are its own minutes under another name, so they are never
/// offered as "before" or "after".
public struct SliceNeighbours: Equatable, Sendable {
    public struct Neighbour: Equatable, Sendable {
        public var task: TaskRef
        public var start: Date
        public var end: Date
        /// Seconds of untracked daylight between the slice's edge and this
        /// neighbour's nearest edge — 0 when they touch.
        public var gap: TimeInterval

        public init(task: TaskRef, start: Date, end: Date, gap: TimeInterval) {
            self.task = task
            self.start = start
            self.end = end
            self.gap = gap
        }

        /// "Immediately" before/after, within the tracker's own switch
        /// resolution — anything past the tolerance gets a named gap.
        public var isContiguous: Bool { gap <= SliceNeighbours.contiguityTolerance }
    }

    public var before: Neighbour?
    public var after: Neighbour?

    /// Under a minute between slice and neighbour still reads as
    /// contiguous — the tracker's own switch grace means genuinely
    /// back-to-back activity can journal a few seconds apart.
    public static let contiguityTolerance: TimeInterval = 60

    public init(before: Neighbour? = nil, after: Neighbour? = nil) {
        self.before = before
        self.after = after
    }

    /// The nearest session ending at/before `start` and the nearest one
    /// starting at/after `end`. Ties on the deciding edge break toward the
    /// session covering more of the adjacent time (later start before,
    /// earlier end after) so the reported neighbour is the one actually
    /// touching the slice.
    public static func around(start: Date, end: Date, in sessions: [Session]) -> SliceNeighbours {
        let beforeSession = sessions.filter { $0.end <= start }
            .max { ($0.end, $0.start) < ($1.end, $1.start) }
        let afterSession = sessions.filter { $0.start >= end }
            .min { ($0.start, $0.end) < ($1.start, $1.end) }
        return SliceNeighbours(
            before: beforeSession.map {
                Neighbour(task: $0.task, start: $0.start, end: $0.end,
                          gap: max(0, start.timeIntervalSince($0.end)))
            },
            after: afterSession.map {
                Neighbour(task: $0.task, start: $0.start, end: $0.end,
                          gap: max(0, $0.start.timeIntervalSince(end)))
            })
    }
}

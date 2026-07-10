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

/// Adjacency-based certainty boost for the review drawer (Martin,
/// 2026-07-10: "if the same activity is tracked immediately before and
/// after a slice, that should significantly increase the slice's certainty
/// of being the same activity. If an activity is adjacent only on one side
/// that should also increase its certainty").
///
/// DISPLAY/ORDERING guidance ONLY: nothing here mutates journalled
/// certainty, teaches the attributor, or changes what auto-pushes — the
/// boost ranks and annotates the drawer's assign buttons and the slice
/// detail line. Feeding it into posting semantics would be a deliberate
/// separate decision (tracked in TODO.md).
public struct AdjacencyBoost: Equatable, Sendable {
    // MARK: - Tuning constants
    // All in ONE place so a retune is a one-line edit. Every applied boost
    // is also logged (AppController.adjacencyScores → DebugLog) precisely so
    // these can later be FITTED from correction outcomes — pair the logged
    // boost with the assign that followed to see whether adjacency pointed
    // at what the user actually picked — instead of staying hand-tuned.

    /// Same task tracked immediately on BOTH sides: close this fraction of
    /// the gap between the base certainty and the inferred ceiling.
    public static let bothSidesGapClose = 0.60
    /// Same task tracked immediately on ONE side only: close this fraction.
    /// Kept at half of `bothSidesGapClose` so the two-sided boost decays
    /// CONTINUOUSLY into the one-sided value as one neighbour's gap grows
    /// (see `apply`); retuning it off that ratio introduces a small step at
    /// the handover, which is acceptable for a deliberate retune.
    public static let oneSideGapClose = 0.30
    /// Gaps up to this still count as "immediately" — full boost strength.
    /// Matches the tracker's own switch buffer: genuinely back-to-back
    /// activity can journal a few seconds apart.
    public static let fullStrengthGap: TimeInterval = 30
    /// Strength decays linearly from full at `fullStrengthGap` to ZERO
    /// here — a neighbour a quarter of an hour away says nothing about
    /// what filled the slice.
    public static let zeroStrengthGap: TimeInterval = 15 * 60

    /// The certainty before adjacency was considered.
    public var base: Double
    /// The boosted certainty — never above the ceiling; equal to `base`
    /// when no adjacency applied.
    public var certainty: Double
    /// The human account of the adjacency contribution ("follows Project X
    /// (+18%)"), nil when no boost applied. Shown on hover and logged.
    public var reasoning: String?

    /// The delta adjacency actually added (0 when none).
    public var boost: Double { certainty - base }

    public init(base: Double, certainty: Double, reasoning: String? = nil) {
        self.base = base
        self.certainty = certainty
        self.reasoning = reasoning
    }

    /// How strongly a neighbour at `gap` seconds counts as "immediately"
    /// adjacent: 1 up to the switch buffer, linear to 0 at the far limit.
    /// A negative gap (defensive — `SliceNeighbours` never produces one)
    /// reads as touching.
    public static func strength(gap: TimeInterval) -> Double {
        if gap <= fullStrengthGap { return 1 }
        if gap >= zeroStrengthGap { return 0 }
        return (zeroStrengthGap - gap) / (zeroStrengthGap - fullStrengthGap)
    }

    /// The adjacency-boosted certainty of `candidate` for a slice with the
    /// given journal neighbours. Only a neighbour tracking the SAME task
    /// boosts; `.doNotTrack` never does (a neighbour is evidence FOR a task,
    /// not against tracking). The boost closes a fraction of the gap up to
    /// `ceiling` and never exceeds it — a pin's 1.0 passes through untouched
    /// because the remaining gap is already ≤ 0.
    public static func apply(base: Double, candidate: Target, name: String,
                             neighbours: SliceNeighbours,
                             ceiling: Double = Attributor.inferredCeiling) -> AdjacencyBoost {
        guard case .task(let ref) = candidate else {
            return AdjacencyBoost(base: base, certainty: base)
        }
        let before = neighbours.before.flatMap { $0.task == ref ? $0 : nil }
        let after = neighbours.after.flatMap { $0.task == ref ? $0 : nil }
        let sBefore = before.map { strength(gap: $0.gap) } ?? 0
        let sAfter = after.map { strength(gap: $0.gap) } ?? 0
        guard sBefore > 0 || sAfter > 0 else {
            return AdjacencyBoost(base: base, certainty: base)
        }
        // Both sides average their decays: with one side fully decayed this
        // hands over continuously to the one-sided fraction
        // (bothSides·s/2 == oneSide·s while bothSides == 2·oneSide).
        let fraction = sBefore > 0 && sAfter > 0
            ? bothSidesGapClose * (sBefore + sAfter) / 2
            : oneSideGapClose * max(sBefore, sAfter)
        let boost = fraction * max(0, ceiling - base)
        guard boost > 0 else {
            // Base at/above the ceiling (a pin, or an already-capped rule):
            // nothing to close, and nothing to report — the certainty is
            // already fully accounted for by its own source.
            return AdjacencyBoost(base: base, certainty: base)
        }
        let amount = "+\(Int((boost * 100).rounded()))%"
        let reasoning: String
        if sBefore > 0 && sAfter > 0 {
            let maxGap = max(before?.gap ?? 0, after?.gap ?? 0)
            reasoning = maxGap > fullStrengthGap
                ? "both neighbours \(name) (gaps up to \(gapText(maxGap)), \(amount))"
                : "both neighbours \(name) (\(amount))"
        } else if sBefore > 0, let before {
            reasoning = before.gap > fullStrengthGap
                ? "follows \(name) (\(gapText(before.gap)) gap, \(amount))"
                : "follows \(name) (\(amount))"
        } else {
            let gap = after?.gap ?? 0
            reasoning = gap > fullStrengthGap
                ? "followed by \(name) (\(gapText(gap)) gap, \(amount))"
                : "followed by \(name) (\(amount))"
        }
        return AdjacencyBoost(base: base,
                              certainty: min(ceiling, base + boost),
                              reasoning: reasoning)
    }

    /// Stack/selection aggregation: the MEAN of the per-slice boosted
    /// certainties (and bases). Mean, not max — the assign button answers
    /// "how sure are we that ALL these slices are this task", and a max
    /// would let one strong slice oversell the whole selection. The
    /// aggregate reasoning says how many slices adjacency actually touched,
    /// quoting the strongest slice's own account.
    public static func aggregate(_ perSlice: [AdjacencyBoost]) -> AdjacencyBoost {
        guard !perSlice.isEmpty else { return AdjacencyBoost(base: 0, certainty: 0) }
        if perSlice.count == 1 { return perSlice[0] }
        let n = Double(perSlice.count)
        let base = perSlice.map(\.base).reduce(0, +) / n
        let certainty = perSlice.map(\.certainty).reduce(0, +) / n
        let boosted = perSlice.filter { $0.boost > 0 }
        guard let strongest = boosted.max(by: { $0.boost < $1.boost }),
              let fragment = strongest.reasoning else {
            return AdjacencyBoost(base: base, certainty: certainty)
        }
        let reasoning = boosted.count == perSlice.count
            ? "adjacency on every slice (\(fragment))"
            : "adjacency on \(boosted.count) of \(perSlice.count) slices (\(fragment))"
        return AdjacencyBoost(base: base, certainty: certainty, reasoning: reasoning)
    }

    /// The assign button's hover: the full certainty build — where the base
    /// comes from, what adjacency added, and the result. `sliceCount` > 1
    /// prefixes the mean so a stack's number is never mistaken for a
    /// single-slice read.
    public static func hoverText(sourceWord: String, _ agg: AdjacencyBoost,
                                 sliceCount: Int) -> String {
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        let prefix = sliceCount > 1 ? "mean of \(sliceCount) slices · " : ""
        guard let why = agg.reasoning else { return "\(prefix)\(sourceWord) \(pct(agg.base))" }
        return "\(prefix)\(sourceWord) \(pct(agg.base)) · \(why) → \(pct(agg.certainty))"
    }

    /// Assign-button order (Martin, 2026-07-10: "sorted by decreasing
    /// certainty"): indices by descending certainty, original position
    /// breaking ties — a stable sort, so zero-signal tasks keep their
    /// familiar ranked pick-list order behind the scored ones.
    public static func buttonOrder(certainties: [Double]) -> [Int] {
        certainties.enumerated()
            .sorted { $0.element == $1.element ? $0.offset < $1.offset
                                               : $0.element > $1.element }
            .map(\.offset)
    }

    /// "45s" / "4m" — the reasoning's compact gap vocabulary.
    static func gapText(_ gap: TimeInterval) -> String {
        gap < 60 ? "\(Int(gap.rounded()))s" : "\(Int((gap / 60).rounded()))m"
    }
}

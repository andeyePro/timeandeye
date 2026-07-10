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

/// What filled the time immediately before and after a review slice —
/// read-only context for the slice's detail disclosure, with an explicit
/// gap when the neighbour wasn't back-to-back ("…2h gap"). A neighbour is
/// either an attributed SESSION (tracked time, carries its task) or —
/// via the pending-aware overload — ANOTHER review-queue slice still
/// awaiting its own decision (Martin's retest, 2026-07-10: "Every item
/// shows a gap" — back-to-back pending slices were reporting gaps to some
/// distant tracked session because only sessions were considered).
/// Sessions overlapping the slice itself are its own minutes under
/// another name, so they are never offered as "before" or "after".
public struct SliceNeighbours: Equatable, Sendable {
    public struct Neighbour: Equatable, Sendable {
        /// The attributed session's task — nil when the neighbour is a
        /// pending review slice (nothing is decided about it yet).
        public var task: TaskRef?
        public var start: Date
        public var end: Date
        /// Seconds of untracked daylight between the slice's edge and this
        /// neighbour's nearest edge — 0 when they touch.
        public var gap: TimeInterval
        /// The pending neighbour's surface ("Excel – Budget.xlsx") — what
        /// the drawer labels it by instead of a task name. nil for sessions.
        public var pendingSurface: String?

        /// A neighbour that is itself still awaiting review. Display marks
        /// it distinctly, and `AdjacencyBoost` must never be fed one — a
        /// pending neighbour is evidence of nothing.
        public var isPending: Bool { task == nil }

        public init(task: TaskRef?, start: Date, end: Date, gap: TimeInterval,
                    pendingSurface: String? = nil) {
            self.task = task
            self.start = start
            self.end = end
            self.gap = gap
            self.pendingSurface = pendingSurface
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
    ///
    /// SESSIONS ONLY — this is the overload `AdjacencyBoost` consumers must
    /// use: an attributed neighbour is evidence a task continued across the
    /// slice; a pending neighbour (see the pending-aware overload below) is
    /// evidence of nothing and must never reach the boost.
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

    /// DISPLAY lookup: the nearest candidate each side, whether an
    /// attributed session or another PENDING review slice (Martin's retest,
    /// 2026-07-10: a slice flush against another pending slice must say so,
    /// not report a gap to some distant tracked session). A tie goes to the
    /// session — a task name informs more than "pending review". Callers
    /// pass `pending` without the slice's own row; segments overlapping the
    /// slice are excluded by the same edge filters sessions get, so even an
    /// un-filtered self never appears as its own neighbour.
    public static func around(start: Date, end: Date, in sessions: [Session],
                              pending: [ReviewSegment]) -> SliceNeighbours {
        let tracked = around(start: start, end: end, in: sessions)
        func surface(_ s: ReviewSegment) -> String {
            "\(s.app)\(s.windowTitle.map { " – \($0)" } ?? "")"
        }
        let pendingBefore = pending.filter { $0.end <= start }
            .max { ($0.end, $0.start) < ($1.end, $1.start) }
            .map { Neighbour(task: nil, start: $0.start, end: $0.end,
                             gap: max(0, start.timeIntervalSince($0.end)),
                             pendingSurface: surface($0)) }
        let pendingAfter = pending.filter { $0.start >= end }
            .min { ($0.start, $0.end) < ($1.start, $1.end) }
            .map { Neighbour(task: nil, start: $0.start, end: $0.end,
                             gap: max(0, $0.start.timeIntervalSince(end)),
                             pendingSurface: surface($0)) }
        func nearer(session: Neighbour?, pending: Neighbour?) -> Neighbour? {
            guard let session else { return pending }
            guard let pending else { return session }
            return pending.gap < session.gap ? pending : session
        }
        return SliceNeighbours(before: nearer(session: tracked.before, pending: pendingBefore),
                               after: nearer(session: tracked.after, pending: pendingAfter))
    }

    /// BATCH lookup: both per-slice results (display + adjacency) for many
    /// slices from ONE preloaded session window, partitioned in memory —
    /// the expand-all path must never turn into a journal query per slice
    /// (Martin, 2026-07-10: "intolerably slow"). Callers run a single range
    /// query spanning every slice and hand the result here; each slice's
    /// own `around` filters are applied in memory. `pending` may include
    /// the slices themselves — the edge filters already exclude any
    /// overlapper, so a slice can never read as its own neighbour.
    public static func batch(for segments: [ReviewSegment], sessions: [Session],
                             pending: [ReviewSegment])
        -> [UUID: (display: SliceNeighbours, adjacency: SliceNeighbours)] {
        var out: [UUID: (display: SliceNeighbours, adjacency: SliceNeighbours)] = [:]
        out.reserveCapacity(segments.count)
        for segment in segments {
            out[segment.id] = (
                display: around(start: segment.start, end: segment.end,
                                in: sessions, pending: pending),
                adjacency: around(start: segment.start, end: segment.end, in: sessions))
        }
        return out
    }
}

/// The EXPENSIVE half of a slice's detail disclosure — the ranker's current
/// read plus both neighbour lookups. The cheap half (timestamps, surface,
/// email evidence) renders straight off the queue's own `ReviewSegment`;
/// this half is computed lazily and in batches (see AppController's
/// `requestSliceDetail`) so opening structure — even Expand all over a big
/// backlog — costs nothing per row at render time.
public struct ReviewSliceDetail: Equatable, Sendable {
    public var explanation: AttributionExplanation
    /// Nearest neighbour each side for DISPLAY — sessions or other pending
    /// slices, whichever is nearer.
    public var display: SliceNeighbours
    /// Sessions-only neighbours — the only lookup `AdjacencyBoost` may see.
    public var adjacency: SliceNeighbours

    public init(explanation: AttributionExplanation, display: SliceNeighbours,
                adjacency: SliceNeighbours) {
        self.explanation = explanation
        self.display = display
        self.adjacency = adjacency
    }
}

/// Adjacency-based certainty boost for the review drawer (Martin,
/// 2026-07-10: "if the same activity is tracked immediately before and
/// after a slice, that should significantly increase the slice's certainty
/// of being the same activity. If an activity is adjacent only on one side
/// that should also increase its certainty").
///
/// The drawer's use (`apply`) is DISPLAY/ORDERING guidance: it ranks and
/// annotates the assign buttons and the slice detail line without touching
/// what those slices journalled. The LIVE variant (`live`) is different by
/// Martin's explicit decision (2026-07-10, his): it feeds the
/// attributor's ranked path, so it DOES shape live certainty — what
/// journals, queues and auto-pushes. Same constants for both; every
/// applied boost is logged so corrections can fit them.
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
        // Callers must feed SESSIONS-ONLY neighbours (the two-argument
        // `SliceNeighbours.around`); defensively, a pending neighbour
        // (task nil) matches no candidate here either — a slice still
        // awaiting review is evidence of nothing (Martin, 2026-07-10).
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

    /// LIVE one-sided prior (Martin, 2026-07-10, his): the clock
    /// RUNNING on a task is itself evidence that an ambiguous surface is a
    /// continuation of it — his pushback on parking this until outcome data
    /// existed ("the running timer IS a sound prior"; corrections only tune
    /// the constants). Same maths and reasoning text as a journal
    /// before-neighbour at `gap` seconds, so live and drawer boosts can
    /// never drift apart. Only the running task's own candidate is lifted;
    /// non-task targets (do-not-track) never boost.
    public static func live(base: Double, candidate: Target, name: String,
                            running: Target, gap: TimeInterval,
                            ceiling: Double = Attributor.inferredCeiling) -> AdjacencyBoost {
        guard candidate == running, case .task(let ref) = running else {
            return AdjacencyBoost(base: base, certainty: base)
        }
        let neighbour = SliceNeighbours.Neighbour(
            task: ref, start: .distantPast, end: .distantPast, gap: max(0, gap))
        return apply(base: base, candidate: candidate, name: name,
                     neighbours: SliceNeighbours(before: neighbour), ceiling: ceiling)
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

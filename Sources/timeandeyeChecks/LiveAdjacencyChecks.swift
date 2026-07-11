import Foundation
import timeandeyeCore

/// The live adjacency prior (Martin, 2026-07-10, his): the clock
/// RUNNING on a task lifts that task's candidate for an ambiguous surface —
/// the one-sided `AdjacencyBoost` maths fed live instead of from journal
/// neighbours. These prove the pure variant's numbers, that only the ranked
/// fallback is touched (definitive sources return before it), and that the
/// boost decays to nothing at the same 15-minute horizon as the drawer's.
func liveAdjacencyChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "timeandeye build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment review", status: "Next")]
    // A surface with no evidence pointing anywhere — the ranked fallback.
    let neutral = ActivitySignal(app: "Preview", windowTitle: "holiday-photo.jpg",
                                 timestamp: now)

    c.check("zero gap closes the one-sided fraction exactly") {
        let b = AdjacencyBoost.live(base: 0.6, candidate: .task(.op(1)),
                                    name: "X", running: .task(.op(1)), gap: 0)
        // 0.6 + 0.30 · (0.95 − 0.6) = 0.705
        try expectClose(b.certainty, 0.705)
        try expect(b.reasoning?.contains("follows X") == true,
                   "live boost should read as a follows-neighbour")
    }

    c.check("the boost dies at the drawer's 15-minute horizon") {
        let b = AdjacencyBoost.live(base: 0.6, candidate: .task(.op(1)),
                                    name: "X", running: .task(.op(1)), gap: 15 * 60)
        try expectClose(b.certainty, 0.6)
        try expectNil(b.reasoning)
    }

    c.check("only the running task's own candidate lifts") {
        let other = AdjacencyBoost.live(base: 0.6, candidate: .task(.op(2)),
                                        name: "Y", running: .task(.op(1)), gap: 0)
        try expectClose(other.certainty, 0.6)
        let dnt = AdjacencyBoost.live(base: 0.6, candidate: .doNotTrack,
                                      name: "-", running: .doNotTrack, gap: 0)
        try expectClose(dnt.certainty, 0.6)
    }

    c.check("a base at the ceiling passes through untouched") {
        let b = AdjacencyBoost.live(base: 0.95, candidate: .task(.op(1)),
                                    name: "X", running: .task(.op(1)), gap: 0)
        try expectClose(b.certainty, 0.95)
        try expectNil(b.reasoning)
    }

    c.check("attribute(): continuity lifts the running task on an ambiguous surface") {
        let a = Attributor(instanceHost: host)
        let without = a.attribute(neutral, tasks: tasks, now: now)
        let baseScore = without.ranked.first { $0.target == .task(.op(1)) }?.score ?? 0
        let with = a.attribute(neutral, tasks: tasks, now: now,
                               continuity: .init(target: .task(.op(1)), lastActive: now))
        try expectEq(with.best?.target, .task(.op(1)),
                     "the continuation hypothesis should lead the ranked list")
        let boosted = with.best?.score ?? 0
        try expect(boosted > baseScore, "boost must raise the running task's score")
        try expect(boosted <= 0.95, "never above the inferred ceiling")
        try expect(a.lastLiveBoost != nil, "applied boost must be reported for logging")
    }

    c.check("attribute(): a task the ranker ignored still enters boosted-from-zero") {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(neutral, tasks: [], now: now,
                                 continuity: .init(target: .task(.op(9)), lastActive: now))
        let entry = result.ranked.first { $0.target == .task(.op(9)) }
        // 0 + 0.30 · 0.95 = 0.285 — visible in the switch list, but below
        // every tracking threshold on its own.
        try expectClose(entry?.score ?? -1, 0.285)
    }

    c.check("attribute(): a stale continuity (20 min gap) changes nothing") {
        let a = Attributor(instanceHost: host)
        let stale = Attributor.Continuity(target: .task(.op(1)),
                                          lastActive: now.addingTimeInterval(-20 * 60))
        let with = a.attribute(neutral, tasks: tasks, now: now, continuity: stale)
        let without = a.attribute(neutral, tasks: tasks, now: now)
        try expectEq(with.ranked, without.ranked)
        try expectNil(a.lastLiveBoost)
    }

    c.check("attribute(): definitive sources return before the prior applies") {
        let a = Attributor(instanceHost: host)
        let opPage = ActivitySignal(app: "Chrome", windowTitle: "WP 1",
                                    tabURL: "https://op.example.com/work_packages/1",
                                    timestamp: now)
        // Clock running on op(2); the page IS op(1) — the URL wins untouched.
        let result = a.attribute(opPage, tasks: tasks, now: now,
                                 continuity: .init(target: .task(.op(2)), lastActive: now))
        try expectEq(result.best?.target, .task(.op(1)))
        try expectClose(result.best?.score ?? 0, 0.95)
        try expectNil(a.lastLiveBoost, "no live boost on a definitive path")
    }

    c.check("attribute(): do-not-track continuity never boosts") {
        let a = Attributor(instanceHost: host)
        let with = a.attribute(neutral, tasks: tasks, now: now,
                               continuity: .init(target: .doNotTrack, lastActive: now))
        let without = a.attribute(neutral, tasks: tasks, now: now)
        try expectEq(with.ranked, without.ranked)
        try expectNil(a.lastLiveBoost)
    }

    // The checks above feed synthetic Continuity values straight to
    // attribute(), so they never exercise how SessionTracker DERIVES the
    // decay clock — and were blind to F2-2: handleFocus treats the focus
    // itself as input (bumping lastInput to `now`) BEFORE reading
    // liveContinuity, so the gap was always 0 and the running task got a
    // FULL boost however long the user had actually been away. Only driving
    // the tracker end-to-end catches it.
    c.check("SessionTracker seam: the live boost decays over real inactivity") {
        let epoch = Date(timeIntervalSince1970: 1_750_000_000)
        func at(_ s: TimeInterval) -> Date { epoch.addingTimeInterval(s) }
        let work = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye build",
                                  timestamp: at(0))
        func ambiguous(_ t: TimeInterval) -> ActivitySignal {
            ActivitySignal(app: "Preview", windowTitle: "holiday-photo.jpg",
                           timestamp: at(t))
        }
        // Establish op(1) as the running task, register a real last-input
        // moment at t100, then focus an evidence-free surface `gap` seconds
        // of inactivity later. The boost the running-clock prior applies is
        // what we read back.
        func boostAfterGap(_ gap: TimeInterval) -> AdjacencyBoost? {
            let a = Attributor(instanceHost: host)
            a.confirm(work, task: .op(1))
            let tracker = SessionTracker(attributor: a, config: TrackerConfig()) { tasks }
            tracker.start(task: .op(1), at: at(0))
            tracker.handle(.focus(work))            // committed op(1); lastInput → t0
            tracker.handle(.input(at(100)))         // last REAL activity at t100
            tracker.handle(.focus(ambiguous(100 + gap)))
            return a.lastLiveBoost
        }
        let full = boostAfterGap(5)                 // within the full-strength window
        let decayed = boostAfterGap(9 * 60)         // 9 min into the decay ramp (< idle stop)

        try expect((full?.boost ?? 0) > 0, "a fresh gap must boost the running task")
        try expect((decayed?.boost ?? 0) > 0, "9 min < 15 min horizon: some boost remains")
        try expect((decayed?.boost ?? 0) < (full?.boost ?? 0) - 0.01,
                   "the boost must DECAY over 9 min of inactivity, not stay at full strength")
    }
}

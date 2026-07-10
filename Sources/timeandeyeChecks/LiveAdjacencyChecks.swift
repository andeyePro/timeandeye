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
}

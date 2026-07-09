import Foundation
import andeyeTTCore

// MARK: - ReviewStack (approvals-drawer spec — stack-by-default drawer shape)

func reviewStackChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
            title: String? = nil, url: String? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title, tabURL: url,
                     start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    c.check("groups identical app|windowTitle|tabURL into one stack, preserving queue order within it") {
        let a1 = seg("Chrome", 0, 60, title: "Insurance")
        let b1 = seg("Ghostty", 100, 160, title: "andeyeTT")
        let a2 = seg("Chrome", 200, 260, title: "Insurance")
        let stacks = [a1, b1, a2].stacked()
        try expectEq(stacks.count, 2, "two distinct surfaces")
        let chromeStack = try unwrap(stacks.first { $0.app == "Chrome" })
        try expectEq(chromeStack.segments.map(\.id), [a1.id, a2.id],
                     "queue order within the stack, not reordered")
    }

    c.check("newest stack first, ordered by each stack's most recent segment") {
        let older = seg("A", 0, 60)          // ends earliest
        let newer = seg("B", 500, 560)       // ends latest
        let middle = seg("C", 200, 260)
        let stacks = [older, newer, middle].stacked()
        try expectEq(stacks.map(\.app), ["B", "C", "A"])
    }

    c.check("total sums segment durations; first/last span the whole group") {
        let a = seg("Chrome", 0, 60, title: "X")          // 60s
        let b = seg("Chrome", 100, 250, title: "X")       // 150s
        let stacks = [a, b].stacked()
        let stack = try unwrap(stacks.first)
        try expectEq(stack.total, 210)
        try expectEq(stack.first, t0)
        try expectEq(stack.last, t0.addingTimeInterval(250))
    }

    c.check("distinct windowTitle/tabURL on the same app never collapse together") {
        let a = seg("Chrome", 0, 60, title: "Tab A")
        let b = seg("Chrome", 60, 120, title: "Tab B")
        try expectEq([a, b].stacked().count, 2)
    }
}

// MARK: - RetroAcceptance.plan (approvals-drawer spec §3)

func retroAcceptanceChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let bar = 0.8

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval) -> ReviewSegment {
        ReviewSegment(app: app, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    func session(_ certainty: Double, task: TaskRef = .op(1),
                _ start: TimeInterval, _ end: TimeInterval) -> Session {
        Session(task: task, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
               certainty: certainty)
    }

    c.check("clears only segments scoring at or above the bar; borderline stays queued") {
        let cleared = seg("Chrome", 0, 60)
        let borderline = seg("Slack", 100, 160)
        let untouched = seg("Mail", 200, 260)
        let scores: [String: Double] = ["Chrome": 0.9, "Slack": bar - 0.01, "Mail": 0.2]
        let plan = RetroAcceptance.plan(pending: [cleared, borderline, untouched], sessions: [], bar: bar) {
            signal in (target: .task(.op(1)), score: scores[signal.app] ?? 0)
        }
        try expectEq(plan.clearances.map(\.segmentID), [cleared.id],
                     "only the >= bar segment clears; the bar-ε segment and the low one stay")
    }

    c.check("lift never lowers certainty, and re-points the session's task") {
        let segment = seg("Chrome", 0, 600)
        // Overlaps the segment, certainty (0.5) below the bar.
        let low = session(0.5, task: .op(9), 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [low], bar: bar) { _ in
            (target: .task(.op(1)), score: 0.95)
        }
        try expectEq(plan.clearances.map(\.target), [.task(.op(1))])
        let lift = try unwrap(plan.lifts.first)
        try expectEq(lift.sessionID, low.id)
        try expectEq(lift.priorTask, .op(9))
        try expectEq(lift.priorCertainty, 0.5)
        try expectEq(lift.newTask, .op(1))
        try expectEq(lift.newCertainty, 0.95, "never lowers — raised to the new score")
    }

    c.check("a session already at/above the bar is untouched (only below-bar sessions lift)") {
        let segment = seg("Chrome", 0, 600)
        let confident = session(0.9, 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [confident], bar: bar) { _ in
            (target: .task(.op(2)), score: 0.95)
        }
        try expect(plan.lifts.isEmpty, "already-confident sessions are not retro-lift candidates")
    }

    c.check("a .doNotTrack clearance clears the row but lifts no session (a Session has no doNotTrack)") {
        let segment = seg("Chrome", 0, 600)
        let low = session(0.5, 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [low], bar: bar) { _ in
            (target: .doNotTrack, score: 0.95)
        }
        try expectEq(plan.clearances.map(\.target), [.doNotTrack])
        try expect(plan.lifts.isEmpty)
    }

    c.check("a non-overlapping session never lifts") {
        let segment = seg("Chrome", 0, 60)
        let elsewhere = session(0.4, 1_000, 1_060)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [elsewhere], bar: bar) { _ in
            (target: .task(.op(1)), score: 0.95)
        }
        try expect(plan.lifts.isEmpty)
    }

    c.check("a session overlapping two cleared segments keeps the higher-scoring lift") {
        let first = seg("Chrome", 0, 100)
        let second = seg("Chrome", 50, 200)
        let spanning = session(0.3, 0, 200)   // overlaps both
        let scores: [TimeInterval: Double] = [0: 0.85, 50: 0.99]
        let plan = RetroAcceptance.plan(pending: [first, second], sessions: [spanning], bar: bar) { signal in
            let offset = signal.timestamp.timeIntervalSince(t0)
            return (target: .task(.op(1)), score: scores[offset] ?? 0)
        }
        try expectEq(plan.lifts.count, 1)
        try expectEq(plan.lifts.first?.newCertainty, 0.99)
    }

    c.check("no clearances -> an empty plan (nothing scores at/above the bar)") {
        let segment = seg("Chrome", 0, 60)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [], bar: bar) { _ in nil }
        try expect(plan.clearances.isEmpty && plan.lifts.isEmpty)
    }
}

// MARK: - Spec §8 acceptance shapes 1–2, purely (no Attributor/AppController —
// the mechanics AppController's applyRetroPlan/undoRetroDigest perform,
// exercised directly against a JournalStore).

func approvalsDrawerAcceptanceChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let bar = 0.8

    c.check("§8.1: a queued span clears on a retro pass, writes a digest, and undo loses nothing") {
        let journal = InMemoryJournalStore()
        let segment = ReviewSegment(app: "Chrome", windowTitle: "Insurance renewal",
                                    start: t0, end: t0.addingTimeInterval(300))
        try journal.save(segment)
        try expectEq(try journal.pendingReview().count, 1)

        // The retro pass: score >= bar (a pin just taught this surface).
        let plan = RetroAcceptance.plan(pending: try journal.pendingReview(), sessions: [], bar: bar) { _ in
            (target: .task(.op(42)), score: 0.9)
        }
        try expect(!plan.clearances.isEmpty)
        try journal.assign(plan.clearances.map(\.segmentID), to: .task(.op(42)))
        let digest = RetroDigest(clearedSegmentIDs: plan.clearances.map(\.segmentID),
                                 target: .task(.op(42)), count: plan.clearances.count,
                                 reason: "confidence rose", priorSessions: [])
        try journal.saveRetroDigest(digest)
        try expectEq(try journal.pendingReview().count, 0, "cleared")
        try expectEq(try journal.retroDigests(limit: 10).map(\.id), [digest.id], "one receipt")

        // Undo: nothing lost.
        try journal.assign(digest.clearedSegmentIDs, to: nil)
        try journal.deleteRetroDigest(digest.id)
        try expectEq(try journal.pendingReview().map(\.id), [segment.id], "the row comes back")
        try expectEq(try journal.retroDigests(limit: 10).count, 0)
    }

    c.check("§8.2: retro-clearing lifts the overlapping session's certainty into push eligibility") {
        let journal = InMemoryJournalStore()
        let segment = ReviewSegment(app: "Chrome", start: t0, end: t0.addingTimeInterval(600))
        let lowSession = Session(task: .op(7), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 0.5)
        try journal.save(segment)
        try journal.save(lowSession)
        try expectEq(try journal.sessions(needingPushAtOrAbove: bar), [],
                     "below the push bar before the retro pass")

        let plan = RetroAcceptance.plan(pending: [segment], sessions: [lowSession], bar: bar) { _ in
            (target: .task(.op(7)), score: 0.85)
        }
        let lift = try unwrap(plan.lifts.first)
        var lifted = try unwrap(try journal.session(id: lift.sessionID))
        lifted.task = lift.newTask
        lifted.certainty = lift.newCertainty
        try journal.update(lifted)

        try expectEq(try journal.sessions(needingPushAtOrAbove: bar).map(\.id), [lowSession.id],
                     "the lift makes the session push-eligible through the NORMAL sync path")
    }
}

import Foundation
import AmbitickCore

// MARK: - OPURLParser (plan task 3)

func opURLParserChecks(_ c: Checks) {
    let host = "op.example.com"

    c.check("extracts id from work_packages paths") {
        try expectEq(OPURLParser.taskID(in: "https://op.example.com/work_packages/842", instanceHost: host), 842)
        try expectEq(OPURLParser.taskID(in: "https://op.example.com/projects/amb/work_packages/91/activity", instanceHost: host), 91)
    }

    c.check("rejects other hosts and paths") {
        try expectNil(OPURLParser.taskID(in: "https://evil.example.com/work_packages/842", instanceHost: host))
        try expectNil(OPURLParser.taskID(in: "https://op.example.com/projects/amb/overview", instanceHost: host))
        try expectNil(OPURLParser.taskID(in: "https://op.example.com/work_packages/new", instanceHost: host))
        try expectNil(OPURLParser.taskID(in: "not a url", instanceHost: host))
    }
}

// MARK: - LearningStore (plan task 4)

func learningStoreChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: t0)
    let steam = ActivitySignal(app: "Steam", windowTitle: "Library", timestamp: t0)
    let taskA = Target.task(.op(1))
    let taskB = Target.task(.op(2))

    c.check("feature extraction") {
        let sig = ActivitySignal(app: "Chrome", windowTitle: "Q3 Invoice review",
                                 tabURL: "https://docs.google.com/document/d/abc",
                                 timestamp: t0)
        let feats = LearningStore.features(from: sig)
        try expect(feats.contains(Feature(.app, "chrome")))
        try expect(feats.contains(Feature(.titleToken, "invoice")))
        try expect(!feats.contains(Feature(.titleToken, "q3")), "tokens < 3 chars dropped")
        try expect(feats.contains(Feature(.urlHost, "docs.google.com")))
        try expect(feats.contains(Feature(.urlPath, "docs.google.com/document")))
    }

    c.check("learned signal outscores unlearned") {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        store.learn(ghostty, target: taskA)
        let scores = store.scores(for: ghostty, among: [taskA, taskB])
        try expect(scores[taskA]! > scores[taskB]!)
        try expectClose(scores.values.reduce(0, +), 1.0)
    }

    c.check("correction moves the score") {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        store.correct(ghostty, from: taskA, to: taskB)
        let scores = store.scores(for: ghostty, among: [taskA, taskB])
        try expect(scores[taskB]! > scores[taskA]!)
    }

    c.check("do-not-track is learnable") {
        var store = LearningStore()
        store.learn(steam, target: .doNotTrack, weight: 3)
        let scores = store.scores(for: steam, among: [taskA, .doNotTrack])
        try expect(scores[.doNotTrack]! > scores[taskA]!)
    }

    c.check("round-trips through JSON") {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        let back = try JSONDecoder().decode(LearningStore.self,
                                            from: JSONEncoder().encode(store))
        try expectEq(back.scores(for: ghostty, among: [taskA, taskB]),
                     store.scores(for: ghostty, among: [taskA, taskB]))
    }
}

// MARK: - TaskRanker (plan task 5)

func taskRankerChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ranker = TaskRanker()

    func task(_ id: Int, _ subject: String, _ status: String,
              confirmedDaysAgo: Double? = nil) -> WorkTask {
        WorkTask(ref: .op(id), subject: subject, status: status,
                 lastConfirmedAt: confirmedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    c.check("status order ranks") {
        let tasks = [task(1, "a", "Closed"), task(2, "b", "Now"),
                     task(3, "c", "Open"), task(4, "d", "Next")]
        try expectEq(ranker.ranked(tasks, at: now).map(\.subject), ["b", "d", "c", "a"])
    }

    c.check("recently confirmed Closed outranks dormant Open (Timesheets case)") {
        let timesheets = task(1, "Timesheets", "Closed", confirmedDaysAgo: 1)
        let dormant = task(2, "Dormant", "Open")
        try expectEq(ranker.ranked([dormant, timesheets], at: now).first?.subject, "Timesheets")
    }

    c.check("pick list is recent then likely, no duplicates") {
        let tasks = [
            task(1, "recent1", "Open", confirmedDaysAgo: 0.1),
            task(2, "recent2", "Closed", confirmedDaysAgo: 0.2),
            task(3, "likelyNow", "Now"),
            task(4, "likelyNext", "Next"),
            task(5, "tail", "Closed"),
        ]
        let picks = ranker.pickList(tasks, at: now, recentCount: 2, likelyCount: 2)
        try expectEq(picks.map(\.subject), ["recent1", "recent2", "likelyNow", "likelyNext"])
    }
}

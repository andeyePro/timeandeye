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

    c.check("extracts id from PWA-style titles") {
        try expectEq(OPURLParser.taskID(inTitle: "#223 Ambitick | OpenProject"), 223)
        try expectEq(OPURLParser.taskID(inTitle: "Ambitick (#223) - IT | OpenProject"), 223)
        try expectNil(OPURLParser.taskID(inTitle: "My page | OpenProject"))
        try expectNil(OPURLParser.taskID(inTitle: "Fix bug #42 · GitHub"), "needs OpenProject in title")
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

// MARK: - FuzzyMatch

func fuzzyMatchChecks(_ c: Checks) {
    func task(_ subject: String, project: String? = nil) -> WorkTask {
        WorkTask(ref: .op(subject.count), subject: subject, project: project, status: "Open")
    }

    c.check("substring beats subsequence; prefix beats both") {
        let tasks = [task("andeye email triage"), task("Timesheets"),
                     task("Time entry models"), task("Investment")]
        let hits = FuzzyMatch.filter(tasks, query: "tim")
        try expectEq(hits.first?.subject, "Timesheets", "prefix match ranks first")
        try expect(hits.contains { $0.subject == "Time entry models" })
        try expect(!hits.contains { $0.subject == "Investment" })
    }

    c.check("subsequence catches abbreviations and project names") {
        let tasks = [task("andeye email triage"), task("Blobs", project: "andeye Ltd")]
        try expect(FuzzyMatch.filter(tasks, query: "aeml").first?.subject == "andeye email triage")
        try expect(FuzzyMatch.filter(tasks, query: "ltd").contains { $0.subject == "Blobs" })
    }

    c.check("empty query passes everything through unchanged") {
        let tasks = [task("a"), task("b")]
        try expectEq(FuzzyMatch.filter(tasks, query: "  ").map(\.subject), ["a", "b"])
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

    c.check("tasks assigned to others sink until tracked") {
        let mine = TaskRanker(config: RankingConfig(currentUser: "Martin Currie"))
        let othersNow = WorkTask(ref: .op(1), subject: "claudes", status: "Now",
                                 assignee: "Claude AI")
        let myOpen = WorkTask(ref: .op(2), subject: "mine", status: "Open",
                              assignee: "Martin Currie")
        let unassigned = WorkTask(ref: .op(3), subject: "nobody", status: "Open")
        try expectEq(mine.ranked([othersNow, myOpen, unassigned], at: now).map(\.subject),
                     ["mine", "nobody", "claudes"])
        // once the user tracks it, it ranks normally again
        let tracked = WorkTask(ref: .op(1), subject: "claudes", status: "Now",
                               lastConfirmedAt: now, assignee: "Claude AI")
        try expectEq(mine.ranked([tracked, myOpen], at: now).first?.subject, "claudes")
    }

    c.check("pick list is recent first, then everything ranked, no duplicates") {
        let tasks = [
            task(1, "recent1", "Open", confirmedDaysAgo: 0.1),
            task(2, "recent2", "Closed", confirmedDaysAgo: 0.2),
            task(3, "likelyNow", "Now"),
            task(4, "likelyNext", "Next"),
            task(5, "tail", "Closed"),
        ]
        // No caps now: recently-confirmed first (most recent first), then the
        // rest in ranked order — the whole scrollable list.
        let picks = ranker.recentThenRanked(tasks, at: now)
        try expectEq(picks.map(\.subject), ["recent1", "recent2", "likelyNow", "likelyNext", "tail"])
    }
}

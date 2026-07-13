import Foundation
import timeandeyeCore

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
        try expectEq(OPURLParser.taskID(inTitle: "#223 timeandeye | OpenProject"), 223)
        try expectEq(OPURLParser.taskID(inTitle: "timeandeye (#223) - IT | OpenProject"), 223)
        try expectNil(OPURLParser.taskID(inTitle: "My page | OpenProject"))
        try expectNil(OPURLParser.taskID(inTitle: "Fix bug #42 · GitHub"), "needs OpenProject in title")
    }
}

// MARK: - LearningStore (plan task 4)

func learningStoreChecks(_ c: Checks) {
    c.check("partial match on a WELL-TAUGHT task beats a never-taught task (B5: no worse-with-use)") {
        var store = LearningStore()
        // Teach task A hard on a rich signal (many features), many times.
        let taught = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye build",
                                    tabURL: "https://github.com/andeyePro/timeandeye",
                                    timestamp: Date(timeIntervalSince1970: 1_750_000_000))
        for _ in 0..<25 { store.learn(taught, target: .task(.op(1)), weight: 2) }
        // A PARTIALLY matching signal: same app, different title/url — the
        // app feature matches the training, the rest don't. The old scoring
        // punished every unmatched feature by log(0.1/(total+1)), which GREW
        // with training, so the never-taught op(2) won and attribution got
        // worse the more you taught it.
        let partial = ActivitySignal(app: "Ghostty", windowTitle: "release notes",
                                     tabURL: nil,
                                     timestamp: Date(timeIntervalSince1970: 1_750_000_600))
        let scores = store.scores(for: partial,
                                  among: [.task(.op(1)), .task(.op(2))])
        try expect((scores[.task(.op(1))] ?? 0) > (scores[.task(.op(2))] ?? 0),
                   "real positive evidence must outrank no evidence")
    }

    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye", timestamp: t0)
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

    c.check("backend text never becomes a learned feature (Xero T&Cs compliance freeze)") {
        // Xero API data must never train/enhance any model. The learner's
        // features must come only from the SENSOR signal; the backend task's
        // subject/project (API data) must not appear anywhere in the
        // persisted model — the task GUID may (it's a class label/reference).
        let xeroSubject = "XERO-API-SOURCED-PROJECT-TITLE-9Z7Q"
        let xeroTask = WorkTask(ref: .remote("guid-compliance-1"),
                                subject: xeroSubject, project: "Xero Client Co",
                                status: "ACTIVE")
        var store = LearningStore()
        // Full learn cycle against the Xero task from an ordinary sensor signal.
        store.learn(ghostty, target: .task(xeroTask.ref), weight: 2)
        store.correct(steam, to: .task(.op(1)), weight: 2, displacingRanked: .task(xeroTask.ref))
        let json = String(data: try JSONEncoder().encode(store), encoding: .utf8)!
        try expect(!json.contains(xeroSubject), "API-sourced subject leaked into the model")
        try expect(!json.contains("Xero Client Co"), "API-sourced project leaked into the model")
        try expect(json.contains("guid-compliance-1"),
                   "the ref IS present — as a label, which is the documented boundary")
        // And the feature extractor structurally cannot see task metadata:
        // its only input is the sensor ActivitySignal.
        let feats = LearningStore.features(from: ghostty).map(\.value)
        try expect(!feats.contains { $0.contains("xero") },
                   "no backend-derived feature values from a non-Xero signal")
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
        store.correct(ghostty, to: taskB, weight: 2, displacingRanked: taskA)
        let scores = store.scores(for: ghostty, among: [taskA, taskB])
        try expect(scores[taskB]! > scores[taskA]!)
    }

    c.check("do-not-track is learnable") {
        var store = LearningStore()
        store.learn(steam, target: .doNotTrack, weight: 3)
        let scores = store.scores(for: steam, among: [taskA, .doNotTrack])
        try expect(scores[.doNotTrack]! > scores[taskA]!)
    }

    c.check("heavier learn weight raises the learned score") {
        var lo = LearningStore(); lo.learn(ghostty, target: taskA); lo.learn(ghostty, target: taskB)
        var hi = lo; hi.learn(ghostty, target: taskA, weight: 4)
        let h = hi.scores(for: ghostty, among: [taskA, taskB])
        try expect(h[taskA]! > lo.scores(for: ghostty, among: [taskA, taskB])[taskA]!)
        try expect(h[taskA]! > h[taskB]!)
    }

    c.check("round-trips through JSON") {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        let back = try JSONDecoder().decode(LearningStore.self,
                                            from: JSONEncoder().encode(store))
        try expectEq(back.scores(for: ghostty, among: [taskA, taskB]),
                     store.scores(for: ghostty, among: [taskA, taskB]))
    }

    c.check("learnedValues returns positively-associated values, excludes hour") {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)   // app=ghostty, titleToken=timeandeye, hourOfDay=N
        let vals = store.learnedValues(for: taskA)
        try expect(vals.contains("timeandeye"), "learned titleToken surfaced")
        try expect(vals.contains("ghostty"), "learned app surfaced")
        try expect(!vals.contains(where: { Int($0) != nil }), "hourOfDay value not returned")
        try expect(store.learnedValues(for: taskB).isEmpty, "unrelated target has none")
    }

    c.check("learnedValues drops a value corrected away (net weight <= 0)") {
        var store = LearningStore()
        store.learn(steam, target: taskA)              // titleToken=library on A
        store.correct(steam, to: taskB, weight: 2, displacingRanked: taskA)   // -1 from A, +2 to B
        try expect(!store.learnedValues(for: taskA).contains("library"), "corrected-away value gone")
        try expect(store.learnedValues(for: taskB).contains("library"), "now associated with B")
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

    c.check("learned association finds a task with zero subject overlap") {
        let governance = WorkTask(ref: .op(7), subject: "Q3 governance", status: "Open")
        let timesheets = WorkTask(ref: .op(8), subject: "Timesheets", status: "Open")
        let learned: (TaskRef) -> [String] = { $0 == .op(7) ? ["voting", "client-work"] : [] }
        let hits = FuzzyMatch.filter([governance, timesheets], query: "voting",
                                     learnedValues: learned)
        try expect(hits.contains { $0.subject == "Q3 governance" },
                   "learned titleToken 'voting' surfaces the task")
        try expect(!hits.contains { $0.subject == "Timesheets" },
                   "unrelated task with no learned match is excluded")
    }

    c.check("a weak subsequence-only learned hit does not admit an off-topic task") {
        let governance = WorkTask(ref: .op(7), subject: "Q3 governance", status: "Open")
        // "vtng" is a subsequence of "voting" (score 1) but not a substring —
        // too weak to pull in a task whose visible text doesn't match at all.
        let learned: (TaskRef) -> [String] = { $0 == .op(7) ? ["voting"] : [] }
        try expect(FuzzyMatch.filter([governance], query: "vtng",
                                     learnedValues: learned).isEmpty)
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

    c.check("recent-first block has a horizon: an ancient one-off never outranks a live Now task (B16)") {
        // Journal back-fill gives EVERY ever-tracked task a lastConfirmedAt;
        // without a horizon a task touched once in March sat above
        // never-tracked "Now" work forever.
        let tasks = [
            task(1, "ancient", "Closed", confirmedDaysAgo: 60),
            task(2, "liveNow", "Now"),
            task(3, "fresh", "Open", confirmedDaysAgo: 1),
        ]
        let picks = ranker.recentThenRanked(tasks, at: now)
        try expectEq(picks.first?.subject, "fresh", "inside the horizon: recent-first holds")
        try expect(picks.map(\.subject).firstIndex(of: "liveNow")!
                    < picks.map(\.subject).firstIndex(of: "ancient")!,
                   "outside the horizon: ranking wins over stale recency")
    }

    c.check("the Unknown sentinel never appears in the pick list, however it got into the input") {
        let tasks = [task(1, "real", "Open"), WorkTask.unknown,
                     task(2, "recentReal", "Open", confirmedDaysAgo: 0.1)]
        let picks = ranker.recentThenRanked(tasks, at: now)
        try expect(!picks.contains { $0.ref == WorkTask.unknown.ref },
                   "Unknown is review-only — never a pickable task")
        try expectEq(picks.count, 2, "the sentinel is dropped, not just re-sorted")
    }
}

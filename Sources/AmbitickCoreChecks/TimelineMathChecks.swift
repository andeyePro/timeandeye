import Foundation
import AmbitickCore

func timelineMathChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func session(_ id: UUID = UUID(), from: TimeInterval, to: TimeInterval,
                 task: Int = 1) -> Session {
        Session(id: id, task: .op(task), start: t(from), end: t(to), certainty: 1)
    }

    c.check("snap pulls to nearby edges only") {
        let sessions = [session(from: 0, to: 600)]
        try expectEq(TimelineMath.snap(t(595), to: sessions, tolerance: 10), t(600))
        try expectEq(TimelineMath.snap(t(640), to: sessions, tolerance: 10), t(640))
        try expectEq(TimelineMath.snap(t(8), to: sessions, tolerance: 10), t(0))
    }

    c.check("gap bounds come from neighbours; inside a session is nil") {
        let sessions = [session(from: 0, to: 600), session(from: 1800, to: 2400)]
        let gap = try unwrap(TimelineMath.gap(at: t(1000), in: sessions,
                                              within: t(-3600)...t(86_400)))
        try expectEq(gap.start, t(600))
        try expectEq(gap.end, t(1800))
        try expectNil(TimelineMath.gap(at: t(300), in: sessions, within: t(0)...t(3600)))
    }

    c.check("trims eat into neighbours; swallowed or sub-minute become deletes") {
        let before = session(from: 0, to: 600)
        let after = session(from: 1200, to: 1260)        // 1 min
        let inside = session(from: 800, to: 900)
        let trims = TimelineMath.trims(for: t(550), t(1230),
                                       in: [before, after, inside])
        try expectEq(trims.count, 3)
        let beforeTrim = try unwrap(trims.first { $0.session.id == before.id })
        try expectEq(beforeTrim.session.end, t(550))
        try expect(!beforeTrim.delete)
        let afterTrim = try unwrap(trims.first { $0.session.id == after.id })
        try expect(afterTrim.delete, "trimmed below a minute must delete")
        let insideTrim = try unwrap(trims.first { $0.session.id == inside.id })
        try expect(insideTrim.delete, "fully swallowed must delete")
    }

    c.check("split moves selected ranges to target, keeps the rest") {
        let s = session(from: 0, to: 600, task: 1)        // 10 min on task 1
        let pieces = TimelineMath.split(s, reassign: [(t(120), t(300))], to: .op(2))
        try expectEq(pieces.count, 3)
        try expectEq(pieces.map(\.task), [.op(1), .op(2), .op(1)])
        try expectEq(pieces[0].start, t(0)); try expectEq(pieces[0].end, t(120))
        try expectEq(pieces[1].start, t(120)); try expectEq(pieces[1].end, t(300))
        try expectEq(pieces[2].start, t(300)); try expectEq(pieces[2].end, t(600))
    }

    c.check("split with a leading range yields two pieces") {
        let s = session(from: 0, to: 600, task: 1)
        let pieces = TimelineMath.split(s, reassign: [(t(0), t(240))], to: .op(2))
        try expectEq(pieces.map(\.task), [.op(2), .op(1)])
        try expectEq(pieces[0].end, t(240))
    }

    c.check("latest block walks back over <1h gaps") {
        let morning = session(from: 0, to: 1800)
        let later1 = session(from: 20_000, to: 21_000)
        let later2 = session(from: 22_000, to: 23_000)   // 1000s gap from later1
        let block = try unwrap(TimelineMath.latestBlock(in: [morning, later1, later2]))
        try expectEq(block.start, t(20_000))
        try expectEq(block.end, t(23_000))
    }
}

func timeAggregatorChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let localID = UUID()

    c.check("project > task > app hierarchy with local grouping") {
        let tasks = [
            WorkTask(ref: .op(1), subject: "Ambitick", project: "IT", status: "Now"),
            WorkTask(ref: .op(2), subject: "Email", project: "Admin", status: "Now"),
            WorkTask(ref: .local(localID), subject: "Chess", status: "Open"),
        ]
        let sessions = [
            Session(task: .op(1), start: t(0), end: t(3600), certainty: 1),
            Session(task: .op(1), start: t(4000), end: t(5800), certainty: 1),
            Session(task: .op(2), start: t(6000), end: t(6600), certainty: 1),
            Session(task: .local(localID), start: t(7000), end: t(7300), certainty: 1),
        ]
        let spans = [
            FocusSpan(target: .task(.op(1)), certainty: 1,
                      signal: ActivitySignal(app: "Ghostty", timestamp: t(0)),
                      start: t(0), end: t(3000)),
            FocusSpan(target: .task(.op(1)), certainty: 1,
                      signal: ActivitySignal(app: "Chrome", timestamp: t(3000)),
                      start: t(3000), end: t(3600)),
        ]
        let nodes = TimeAggregator.byProject(sessions: sessions, tasks: tasks, spans: spans)
        try expectEq(nodes.map(\.label), ["IT", "Admin", "Personal"])
        try expectClose(nodes[0].seconds, 5400)
        try expectEq(nodes[0].children.first?.label, "Ambitick")
        let apps = nodes[0].children.first?.children ?? []
        try expectEq(apps.map(\.label), ["Ghostty", "Chrome"])
        try expectClose(apps[0].seconds, 3000)
        try expectEq(nodes[2].children.first?.label, "Chess")
    }
}

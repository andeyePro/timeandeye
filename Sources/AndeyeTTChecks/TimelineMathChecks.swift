import Foundation
import AndeyeTTCore

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

    c.check("keyboard nav: empty list -> nil") {
        try expectNil(TimelineMath.keyboardMove(in: [], anchor: nil, focus: nil,
                                                forward: true, extend: false))
    }

    c.check("keyboard nav: first arrow lands on an end, then steps + clamps") {
        let ids = [UUID(), UUID(), UUID()]
        // No focus yet: right lands on first, left lands on last.
        let r0 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: nil, focus: nil,
                                                      forward: true, extend: false))
        try expectEq(r0.focus, ids[0])
        try expectEq(r0.anchor, ids[0])
        try expectEq(r0.selection, [ids[0]])
        let l0 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: nil, focus: nil,
                                                      forward: false, extend: false))
        try expectEq(l0.focus, ids[2])
        // Step forward one.
        let r1 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[0], focus: ids[0],
                                                      forward: true, extend: false))
        try expectEq(r1.focus, ids[1])
        try expectEq(r1.selection, [ids[1]])
        // Clamp at the right end (no wrap).
        let rEnd = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[2], focus: ids[2],
                                                        forward: true, extend: false))
        try expectEq(rEnd.focus, ids[2])
        // Clamp at the left end.
        let lEnd = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[0], focus: ids[0],
                                                        forward: false, extend: false))
        try expectEq(lEnd.focus, ids[0])
    }

    c.check("keyboard nav: shift extends a contiguous range from the anchor") {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        // Focus on index 1, shift-right grows to {1,2}, anchor stays.
        let g1 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[1], focus: ids[1],
                                                      forward: true, extend: true))
        try expectEq(g1.anchor, ids[1])
        try expectEq(g1.focus, ids[2])
        try expectEq(g1.selection, Set([ids[1], ids[2]]))
        // Continue shift-right -> {1,2,3}.
        let g2 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[1], focus: ids[2],
                                                      forward: true, extend: true))
        try expectEq(g2.selection, Set([ids[1], ids[2], ids[3]]))
        // Shift-left from focus 3 shrinks back toward the anchor -> {1,2}.
        let s1 = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: ids[1], focus: ids[3],
                                                      forward: false, extend: true))
        try expectEq(s1.anchor, ids[1])
        try expectEq(s1.focus, ids[2])
        try expectEq(s1.selection, Set([ids[1], ids[2]]))
    }

    c.check("keyboard nav: shift seeds the anchor from the current focus") {
        let ids = [UUID(), UUID(), UUID()]
        // No anchor yet but focus on index 1: shift-right pins the anchor at 1
        // and extends to {1,2}.
        let g = try unwrap(TimelineMath.keyboardMove(in: ids, anchor: nil, focus: ids[1],
                                                     forward: true, extend: true))
        try expectEq(g.anchor, ids[1])
        try expectEq(g.focus, ids[2])
        try expectEq(g.selection, Set([ids[1], ids[2]]))
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

    c.check("mergeAdjacent fuses butting same-task slices, keeps data") {
        let a = Session(task: .op(1), start: t(0), end: t(300), certainty: 0.9, comment: "first")
        let b = Session(task: .op(1), start: t(300), end: t(600), certainty: 0.7, comment: "second")
        let c2 = Session(task: .op(2), start: t(600), end: t(900), certainty: 1)
        let d = Session(task: .op(1), start: t(900), end: t(1200), certainty: 1)
        let merged = TimelineMath.mergeAdjacent([a, b, c2, d])
        // a+b fuse; c2 (other task) and d (not adjacent to a/b) stay separate.
        try expectEq(merged.count, 3)
        try expectEq(merged[0].id, a.id)            // survivor keeps first id
        try expectEq(merged[0].start, t(0))
        try expectEq(merged[0].end, t(600))
        try expectEq(merged[0].comment, "first; second")
        try expectClose(merged[0].certainty, 0.7)
        try expect(!merged[0].pushedToOP)
        try expectEq(merged.map(\.task), [.op(1), .op(2), .op(1)])
    }

    c.check("mergeAdjacent keeps a real gap discrete (manual Stop→Start boundary)") {
        // Policy: adjacent same-task slices fold into one; the ONLY discrete
        // boundary is the untracked gap a manual Stop→Start leaves. A contiguous
        // continue/revert/away-claim butts up (<= tolerance) and merges; a stop
        // then restart leaves seconds of untracked time and stays two slices.
        let stopped = Session(task: .op(1), start: t(0), end: t(300), certainty: 1, comment: "designed")
        let restarted = Session(task: .op(1), start: t(305), end: t(600), certainty: 1, comment: "tested")
        let kept = TimelineMath.mergeAdjacent([stopped, restarted])
        try expectEq(kept.count, 2, "5s untracked gap > 2s tolerance stays discrete")
        try expectEq(kept.map(\.comment), ["designed", "tested"])

        // Continue/revert/claim: butting same-task slices DO fold.
        let prior = Session(task: .op(1), start: t(0), end: t(300), certainty: 1)
        let continued = Session(task: .op(1), start: t(300), end: t(600), certainty: 1)
        try expectEq(TimelineMath.mergeAdjacent([prior, continued]).count, 1)
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

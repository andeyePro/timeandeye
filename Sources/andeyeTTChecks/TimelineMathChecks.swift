import Foundation
import andeyeTTCore

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

    c.check("splitAcross moves windows lying in DIFFERENT rows of one block") {
        // Regression: the live block folds earlier contiguous same-task journal
        // rows into ONE displayed slice, so a window selected in the strip can
        // belong to an earlier row than the caller's own. The old code split
        // only that one row and dropped the rest — the move did nothing. Here a
        // window is selected in each of two rows; BOTH must reassign.
        let s1 = session(from: 0, to: 600, task: 1)
        let s2 = session(from: 600, to: 1200, task: 1)
        let work = TimelineMath.splitAcross([s1, s2],
                                            reassign: [(t(120), t(300)), (t(700), t(900))],
                                            to: .op(2))
        try expectEq(work.count, 2)                 // both rows changed
        let w1 = try unwrap(work.first { $0.session.id == s1.id })
        try expectEq(w1.pieces.map(\.task), [.op(1), .op(2), .op(1)])
        let w2 = try unwrap(work.first { $0.session.id == s2.id })
        try expectEq(w2.pieces.map(\.task), [.op(1), .op(2), .op(1)])
    }

    c.check("splitAcross touches only the rows the ranges hit") {
        // Selecting one window early in the block moves JUST that window: the
        // current (latest) row AND an unselected same-task row between them are
        // left untouched, so nothing but the picked window changes task.
        let early = session(from: 0, to: 600, task: 1)
        let middle = session(from: 600, to: 1200, task: 1)   // unselected, same task
        let latest = session(from: 1200, to: 1800, task: 1)  // the live tail
        let work = TimelineMath.splitAcross([early, middle, latest],
                                            reassign: [(t(120), t(300))], to: .op(2))
        try expectEq(work.count, 1)
        try expectEq(work[0].session.id, early.id)
        try expectEq(work[0].pieces.map(\.task), [.op(1), .op(2), .op(1)])
    }

    c.check("split never reattributes UNSELECTED sub-minute time at a range edge") {
        // A selection ending 30s before the session end leaves a sub-minute
        // tail on the ORIGINAL task. The old absorb-tiny-fragment logic flipped
        // that 30s to the target — moving time the user never selected. It must
        // stay put, even as a short sliver.
        let s = session(from: 0, to: 600, task: 1)
        let pieces = TimelineMath.split(s, reassign: [(t(120), t(570))], to: .op(2))
        try expectEq(pieces.map(\.task), [.op(1), .op(2), .op(1)])
        try expectEq(pieces[2].start, t(570)); try expectEq(pieces[2].end, t(600))
        // Conservation: the pieces still tile the whole session, no gap.
        try expectEq(pieces[0].start, t(0)); try expectEq(pieces[2].end, t(600))
    }

    c.check("split MOVES a genuinely-selected sub-minute window") {
        // A selected window under a minute used to be absorbed back onto the
        // original task — a silent no-op, the very bug class this fixes. It
        // must now move.
        let s = session(from: 0, to: 600, task: 1)
        let pieces = TimelineMath.split(s, reassign: [(t(120), t(150))], to: .op(2))
        try expectEq(pieces.map(\.task), [.op(1), .op(2), .op(1)])
        try expectEq(pieces[1].start, t(120)); try expectEq(pieces[1].end, t(150))
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

    c.check("joinComments drops nil/empty, keeps order — the one shared joiner") {
        // mergeAdjacent, foldLive and the live display all join through this;
        // if it drifted from "; " a merged slice would read differently from
        // a live one carrying the same comments.
        try expectEq(TimelineMath.joinComments(["design", nil, "", "test"]), "design; test")
        try expectEq(TimelineMath.joinComments(["only"]), "only")
        try expectNil(TimelineMath.joinComments([nil, ""]))
    }

    c.check("foldLive folds contiguous same-task rows and CARRIES their comments") {
        // Mid-tracking flushes journal rows that butt up against the live
        // start; the displayed block folds them. Martin's bug: a folded row's
        // stored comment vanished from the timeline (only stop + a gap brought
        // it back), because the fold dropped the rows without keeping their
        // comments. The fold must extend the start AND surface them,
        // oldest-first, matching mergeAdjacent's join order.
        let older = Session(task: .op(1), start: t(0), end: t(300), certainty: 1, comment: "spec")
        let newer = Session(task: .op(1), start: t(300), end: t(600), certainty: 1, comment: "build")
        let fold = TimelineMath.foldLive([newer, older], task: .op(1), liveStart: t(600))
        try expectEq(fold.start, t(0))
        try expectEq(fold.remaining.count, 0)
        try expectEq(fold.foldedComment, "spec; build")
    }

    c.check("foldLive stops at a gap or another task — those rows stay discrete") {
        // A stop→start gap or an interleaved other-task slice breaks the
        // chain: rows beyond it keep drawing (and commenting) as themselves.
        let gapped = Session(task: .op(1), start: t(0), end: t(280), certainty: 1,
                             comment: "before the gap")
        let otherTask = Session(task: .op(2), start: t(290), end: t(600), certainty: 1)
        let fold = TimelineMath.foldLive([gapped, otherTask], task: .op(1), liveStart: t(600))
        try expectEq(fold.start, t(600))
        try expectEq(fold.remaining.count, 2)
        try expectNil(fold.foldedComment)
    }

    c.check("live display comment = folded stored comments + pending note, no duplication") {
        // The timeline composes the live block's comment as stored-then-
        // pending. The editor shows the stored part read-only and edits ONLY
        // the pending note, so open→save-unchanged must round-trip losslessly:
        // an empty pending adds nothing, and the pending never absorbs the
        // stored part (or vice versa).
        let stored = TimelineMath.foldLive(
            [Session(task: .op(1), start: t(0), end: t(300), certainty: 1, comment: "spec"),
             Session(task: .op(1), start: t(300), end: t(600), certainty: 1, comment: "build")],
            task: .op(1), liveStart: t(600)).foldedComment
        try expectEq(TimelineMath.joinComments([stored, "pending"]), "spec; build; pending")
        try expectEq(TimelineMath.joinComments([stored, ""]), "spec; build")
        try expectEq(TimelineMath.joinComments([nil, "pending"]), "pending")
    }

    c.check("latest block walks back over <1h gaps") {
        let morning = session(from: 0, to: 1800)
        let later1 = session(from: 20_000, to: 21_000)
        let later2 = session(from: 22_000, to: 23_000)   // 1000s gap from later1
        let block = try unwrap(TimelineMath.latestBlock(in: [morning, later1, later2]))
        try expectEq(block.start, t(20_000))
        try expectEq(block.end, t(23_000))
    }

    c.check("clampViewport: span clamps to [minSpan, day] and stays in bounds") {
        let day = t(0)...t(86_400)
        // Too-small span grows to the minimum.
        let tiny = TimelineMath.clampViewport(start: t(1000), span: 10,
                                              bounds: day, minSpan: 900)
        try expectEq(tiny.span, 900)
        try expectEq(tiny.start, t(1000))
        // Too-large span shrinks to the whole day, pinned at the day start.
        let huge = TimelineMath.clampViewport(start: t(-5000), span: 200_000,
                                              bounds: day, minSpan: 900)
        try expectEq(huge.span, 86_400)
        try expectEq(huge.start, t(0))
    }

    c.check("clampViewport: start slides back inside the bounds") {
        let day = t(0)...t(86_400)
        // Panned past the right edge: the window slides back flush.
        let right = TimelineMath.clampViewport(start: t(85_000), span: 3600,
                                               bounds: day, minSpan: 900)
        try expectEq(right.start, t(82_800))
        try expectEq(right.span, 3600)
        // Panned past the left edge: pinned at the day start.
        let left = TimelineMath.clampViewport(start: t(-3600), span: 3600,
                                              bounds: day, minSpan: 900)
        try expectEq(left.start, t(0))
        // Inside the bounds: untouched.
        let mid = TimelineMath.clampViewport(start: t(30_000), span: 3600,
                                             bounds: day, minSpan: 900)
        try expectEq(mid.start, t(30_000))
    }

    c.check("clampViewport: minSpan wider than the bounds cannot escape them") {
        let hour = t(0)...t(3600)
        let r = TimelineMath.clampViewport(start: t(500), span: 10,
                                           bounds: hour, minSpan: 7200)
        try expectEq(r.span, 3600)
        try expectEq(r.start, t(0))
    }

    c.check("tickStep: picks the smallest step keeping labels >= minGap apart") {
        // A full day on a 390 pt phone: hourly ticks would be 16 pt apart —
        // steps up to 3 h (48.75 pt).
        try expectEq(TimelineMath.tickStep(span: 86_400, width: 390, minGap: 44), 3 * 3600)
        // An 8 h working view on the same width: hourly fits (48.75 pt).
        try expectEq(TimelineMath.tickStep(span: 8 * 3600, width: 390, minGap: 44), 3600)
        // Zoomed to an hour: quarter-hour ticks (97.5 pt).
        try expectEq(TimelineMath.tickStep(span: 3600, width: 390, minGap: 44), 900)
        // Tight zoom: the 5-minute floor.
        try expectEq(TimelineMath.tickStep(span: 900, width: 390, minGap: 44), 300)
    }

    c.check("tickStep: degenerate inputs fall back to the coarsest step") {
        try expectEq(TimelineMath.tickStep(span: 0, width: 390, minGap: 44), 12 * 3600)
        try expectEq(TimelineMath.tickStep(span: 86_400, width: 0, minGap: 44), 12 * 3600)
    }
}

func spanAllocationChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func session(_ id: UUID = UUID(), from: TimeInterval, to: TimeInterval,
                task: Int = 1, pushed: Bool = false) -> Session {
        Session(id: id, task: .op(task), start: t(from), end: t(to), certainty: 1,
               pushedToOP: pushed)
    }

    c.check("full-inside session -> a single repoint, carrying the ORIGINAL untouched") {
        // The payload is the session BEFORE the task change: the caller
        // re-points it via reassignTimelineSessions, which mutates the task
        // itself and needs the pre-change value for its own undo record.
        let s = session(from: 100, to: 500, task: 1)
        let plan = SpanAllocation.plan(sessions: [s], range: (t(0), t(600)), to: .op(2))
        try expectEq(plan.count, 1)
        guard case .repoint(let original) = plan[0] else {
            throw CheckFailure(description: "expected .repoint, got \(plan[0])")
        }
        try expectEq(original.id, s.id)
        try expectEq(original.task, .op(1))
        try expectEq(original.start, t(100)); try expectEq(original.end, t(500))
    }

    c.check("full-inside session already on target -> no action (nothing to do)") {
        let s = session(from: 100, to: 500, task: 2)
        let plan = SpanAllocation.plan(sessions: [s], range: (t(0), t(600)), to: .op(2))
        try expect(plan.isEmpty)
    }

    c.check("range strictly inside a session -> both-edge split into 3 pieces") {
        let s = session(from: 0, to: 600, task: 1)
        let plan = SpanAllocation.plan(sessions: [s], range: (t(120), t(300)), to: .op(2))
        try expectEq(plan.count, 1)
        guard case .split(let original, let pieces) = plan[0] else {
            throw CheckFailure(description: "expected .split, got \(plan[0])")
        }
        try expectEq(original.id, s.id)
        try expectEq(pieces.map(\.task), [.op(1), .op(2), .op(1)])
        try expectEq(pieces[1].start, t(120)); try expectEq(pieces[1].end, t(300))
    }

    c.check("session starting before the range, ending inside it -> left-edge split") {
        // Session [0,300) straddles the range's start edge at 120; the tail
        // from 120..300 (all inside the range) moves, the head stays.
        let s = session(from: 0, to: 300, task: 1)
        let plan = SpanAllocation.plan(sessions: [s], range: (t(120), t(600)), to: .op(2))
        try expectEq(plan.count, 1)
        guard case .split(_, let pieces) = plan[0] else {
            throw CheckFailure(description: "expected .split, got \(plan[0])")
        }
        try expectEq(pieces.map(\.task), [.op(1), .op(2)])
        try expectEq(pieces[0].end, t(120)); try expectEq(pieces[1].start, t(120))
        try expectEq(pieces[1].end, t(300))
    }

    c.check("session starting inside the range, ending after it -> right-edge split") {
        // Session [300,600) straddles the range's end edge at 480; the head
        // 300..480 moves, the tail stays.
        let s = session(from: 300, to: 600, task: 1)
        let plan = SpanAllocation.plan(sessions: [s], range: (t(0), t(480)), to: .op(2))
        try expectEq(plan.count, 1)
        guard case .split(_, let pieces) = plan[0] else {
            throw CheckFailure(description: "expected .split, got \(plan[0])")
        }
        try expectEq(pieces.map(\.task), [.op(2), .op(1)])
        try expectEq(pieces[0].start, t(300)); try expectEq(pieces[0].end, t(480))
        try expectEq(pieces[1].start, t(480)); try expectEq(pieces[1].end, t(600))
    }

    c.check("sessions outside the range are absent from the plan") {
        let before = session(from: -600, to: -60, task: 1)
        let after = session(from: 700, to: 800, task: 1)
        let plan = SpanAllocation.plan(sessions: [before, after], range: (t(0), t(600)), to: .op(2))
        try expect(plan.isEmpty)
    }

    c.check("pushed session is planned exactly like an unpushed one — no special-casing here") {
        // The editor's existing policy (quietly re-queue the OP push) lives
        // in the controller's apply path; the pure plan must not skip or
        // otherwise treat a pushed session differently.
        let pushed = session(from: 100, to: 500, task: 1, pushed: true)
        let plan = SpanAllocation.plan(sessions: [pushed], range: (t(0), t(600)), to: .op(2))
        try expectEq(plan.count, 1)
        guard case .repoint(let original) = plan[0] else {
            throw CheckFailure(description: "expected .repoint, got \(plan[0])")
        }
        try expectEq(original.task, .op(1))
        try expect(original.pushedToOP, "the plan itself doesn't touch pushedToOP either way")
    }

    c.check("Unknown target plans identically to any other task ref") {
        let full = session(from: 100, to: 500, task: 1)
        // Starts before the range: a genuine split, not a second repoint —
        // exercises both action kinds in the same Unknown-target plan.
        let straddling = session(from: -100, to: 200, task: 1)
        let plan = SpanAllocation.plan(sessions: [full, straddling],
                                       range: (t(0), t(600)), to: WorkTask.unknown.ref)
        try expectEq(plan.count, 2)
        var sawRepoint = false
        var sawSplit = false
        for action in plan {
            switch action {
            case .repoint(let original):
                sawRepoint = true
                try expectEq(original.id, full.id)
            case .split(let original, let pieces):
                sawSplit = true
                try expectEq(original.id, straddling.id)
                try expectEq(pieces.last?.task, WorkTask.unknown.ref)
            }
        }
        try expect(sawRepoint, "the fully-inside session should still plan a repoint")
        try expect(sawSplit, "the straddling session should still plan a split")
    }

    c.check("multiple sessions on DIFFERENT tasks are each planned independently") {
        // A span selection isn't scoped to one slice's task — unlike
        // splitAndReassign's same-task filter, plan() must handle a range
        // that crosses sessions belonging to different tasks.
        let a = session(from: 0, to: 300, task: 1)
        let b = session(from: 300, to: 600, task: 2)
        let plan = SpanAllocation.plan(sessions: [a, b], range: (t(0), t(600)), to: .op(3))
        try expectEq(plan.count, 2)
        for action in plan {
            guard case .repoint(let original) = action else {
                throw CheckFailure(description: "expected both to fully repoint, got \(action)")
            }
            try expect(original.task == .op(1) || original.task == .op(2))
        }
    }
}

func timeAggregatorChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let localID = UUID()

    c.check("project > task > app hierarchy with local grouping") {
        let tasks = [
            WorkTask(ref: .op(1), subject: "andeyeTT", project: "IT", status: "Now"),
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
        try expectEq(nodes[0].children.first?.label, "andeyeTT")
        let apps = nodes[0].children.first?.children ?? []
        try expectEq(apps.map(\.label), ["Ghostty", "Chrome"])
        try expectClose(apps[0].seconds, 3000)
        try expectEq(nodes[2].children.first?.label, "Chess")
    }
}

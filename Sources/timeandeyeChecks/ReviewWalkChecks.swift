import Foundation
import timeandeyeCore

// MARK: - Walk-through review (Martin's respec: no whole-day confirm —
// walk the day's slices either direction, dig in at will, ONE click confirms
// exactly the slices actually viewed)

func reviewWalkChecks(_ c: Checks) {
    // Four slices across the day, earliest first — the order the queue's own
    // pendingReview() hands the walk.
    let ids = (0..<4).map { _ in UUID() }

    func fresh() -> ReviewWalk {
        var w = ReviewWalk()
        w.update(order: ids)
        return w
    }

    c.check("→ with no cursor enters the day at the EARLIEST slice and marks it viewed") {
        var w = fresh()
        w.step(.right)
        try expectEq(w.current, ids[0])
        try expectEq(w.viewed, [ids[0]])
    }

    c.check("← with no cursor enters at the LATEST slice — right-to-left is first-class, not a reverse gear") {
        // His respec named BOTH directions ("left to right or right to
        // left"); an evening review naturally starts from the most recent.
        var w = fresh()
        w.step(.left)
        try expectEq(w.current, ids[3])
        try expectEq(w.viewed, [ids[3]])
    }

    c.check("steps walk chronologically both ways and every landing joins the viewed set") {
        var w = fresh()
        w.step(.right)   // ids[0]
        w.step(.right)   // ids[1]
        w.step(.right)   // ids[2]
        w.step(.left)    // back to ids[1] — reversing mid-walk is allowed
        try expectEq(w.current, ids[1])
        try expectEq(w.viewed, [ids[0], ids[1], ids[2]])
    }

    c.check("arrowing past either end stays put — the day has edges, no wrap") {
        // A wrap would silently mark the far end viewed off one keypress
        // too many — exactly the fake "viewed" the design forbids.
        var w = fresh()
        w.step(.left)    // enters at ids[3]
        w.step(.right)   // already at the right edge
        try expectEq(w.current, ids[3])
        try expectEq(w.viewed, [ids[3]], "no phantom visit past the edge")
        w.step(.left)    // ids[2]
        w.step(.left)    // ids[1]
        w.step(.left)    // ids[0]
        w.step(.left)    // left edge — stays
        try expectEq(w.current, ids[0])
    }

    c.check("visit() — a click or an opened disclosure — moves the cursor there and marks it viewed") {
        var w = fresh()
        w.visit(ids[2])
        try expectEq(w.current, ids[2])
        try expect(w.viewed.contains(ids[2]))
        // …and the walk continues FROM the dig-in point, not from where the
        // arrows last were.
        w.step(.right)
        try expectEq(w.current, ids[3])
    }

    c.check("a stale id (not in the queue) is ignored — no phantom joins the viewed set") {
        var w = fresh()
        let ghost = UUID()
        w.visit(ghost)
        try expectNil(w.current)
        try expect(w.viewed.isEmpty)
    }

    c.check("digging in and walking away never unmarks a viewed slice") {
        // "dig into any slice as deep as you like on the way" — expanding,
        // re-visiting, reversing: viewed only ever shrinks when a slice
        // stops being pending, never from more attention.
        var w = fresh()
        w.step(.right)
        w.step(.right)
        w.visit(ids[1])   // re-open the same slice's detail
        w.step(.left)
        try expectEq(w.viewed, [ids[0], ids[1]])
    }

    c.check("update() drops HANDLED slices from viewed but keeps the rest — partial day, come back later, just works") {
        var w = fresh()
        w.step(.right)   // ids[0] viewed
        w.step(.right)   // ids[1] viewed
        // ids[0] and ids[1] get confirmed/assigned away; the queue reloads.
        w.update(order: [ids[2], ids[3]])
        try expect(w.viewed.isEmpty, "handled slices are decided, not merely viewed")
        // The cursor relocated onto UNVIEWED ids[2]; the first arrow press
        // must open it in place — never step past a slice nobody looked at.
        w.step(.right)
        try expectEq(w.current, ids[2], "the walk resumes over what remains")
        try expect(w.viewed.contains(ids[2]), "the resuming press views the slice under the cursor")
        w.step(.right)
        try expectEq(w.current, ids[3], "…and the next press walks on")
        // …while a reload that handles OTHER slices keeps this walk's marks.
        var w2 = fresh()
        w2.visit(ids[2])
        w2.update(order: [ids[0], ids[2]])
        try expectEq(w2.viewed, [ids[2]], "surviving viewed marks persist across reloads")
    }

    c.check("cursor on a handled slice relocates to the nearest survivor — rightward first, else leftward") {
        // "Assign and walk on": the cursor must not fall off the day when
        // its own slice leaves the queue mid-walk.
        var w = fresh()
        w.visit(ids[1])
        w.update(order: [ids[0], ids[2], ids[3]])   // ids[1] assigned away
        try expectEq(w.current, ids[2], "next slice to the right")
        var w2 = fresh()
        w2.visit(ids[3])
        w2.update(order: [ids[0], ids[1]])   // everything rightward gone too
        try expectEq(w2.current, ids[1], "falls back to the nearest on the left")
        var w3 = fresh()
        w3.visit(ids[1])
        w3.update(order: [])
        try expectNil(w3.current, "an emptied queue leaves no cursor")
    }

    c.check("relocation is mechanical, never a view — the cursor moving does not fake attention") {
        // The design's honesty rule: only arrows, clicks and opened
        // disclosures mark viewed. A slice the cursor merely slid onto
        // after an assign has NOT been looked at.
        var w = fresh()
        w.visit(ids[1])
        w.update(order: [ids[0], ids[2], ids[3]])
        try expectEq(w.current, ids[2])
        try expect(!w.viewed.contains(ids[2]), "relocated-onto slice is not viewed")
    }

    c.check("stepping an empty queue is a no-op") {
        var w = ReviewWalk()
        w.step(.right)
        try expectNil(w.current)
        try expect(w.viewed.isEmpty)
    }
}

// MARK: - One-click confirm of exactly the viewed slices

func reviewConfirmChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let taskA = TaskRef.op(1)
    let taskB = TaskRef.op(2)

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval) -> ReviewSegment {
        ReviewSegment(app: app, start: t0.addingTimeInterval(start),
                      end: t0.addingTimeInterval(end))
    }

    func session(_ task: TaskRef, _ start: TimeInterval, _ end: TimeInterval,
                 certainty: Double, pushed: Bool = false,
                 provenance: SessionProvenance? = nil) -> Session {
        Session(task: task, start: t0.addingTimeInterval(start),
                end: t0.addingTimeInterval(end), certainty: certainty,
                pushedToOP: pushed, provenance: provenance)
    }

    /// Scorer stub: app name decides — the plan must group per target.
    func scorer(_ signal: ActivitySignal) -> (target: Target, score: Double)? {
        switch signal.app {
        case "A": return (.task(taskA), 0.6)
        case "B": return (.task(taskB), 0.5)
        case "DNT": return (.doNotTrack, 0.7)
        default: return nil   // nothing matched yet
        }
    }

    c.check("confirm covers exactly the viewed pending slices — unviewed slices never enter the plan") {
        // THE point of the respec: reviewing part of the day must leave the
        // rest completely untouched, not swept along by a day-wide click.
        let s1 = seg("A", 0, 60), s2 = seg("A", 100, 160), s3 = seg("B", 200, 260)
        let plan = ReviewConfirm.plan(viewed: [s1.id, s3.id], pending: [s1, s2, s3],
                                      sessions: [], bar: 0.9, score: scorer)
        let allIDs = plan.assignments.flatMap(\.segmentIDs)
        try expect(!allIDs.contains(s2.id), "unviewed slice must stay out")
        try expectEq(Set(allIDs), [s1.id, s3.id])
        try expectEq(plan.confirmedCount, 2)
    }

    c.check("slices group per scored target, targets and ids in queue order") {
        let s1 = seg("A", 0, 60), s2 = seg("B", 100, 160), s3 = seg("A", 200, 260)
        let plan = ReviewConfirm.plan(viewed: [s1.id, s2.id, s3.id],
                                      pending: [s1, s2, s3],
                                      sessions: [], bar: 0.9, score: scorer)
        try expectEq(plan.assignments.map(\.target), [.task(taskA), .task(taskB)])
        try expectEq(plan.assignments[0].segmentIDs, [s1.id, s3.id])
        try expectEq(plan.assignments[1].segmentIDs, [s2.id])
    }

    c.check("a viewed slice the scorer has no answer for stays queued as unresolved — confirm never invents a target") {
        // "I am happy with what I viewed" needs something ON SHOW to be
        // happy with; a nothing-matched slice has no word to take.
        let s1 = seg("A", 0, 60), s2 = seg("???", 100, 160)
        let plan = ReviewConfirm.plan(viewed: [s1.id, s2.id], pending: [s1, s2],
                                      sessions: [], bar: 0.9, score: scorer)
        try expectEq(plan.unresolved, [s2.id])
        try expectEq(plan.confirmedCount, 1)
    }

    c.check("viewed ids no longer pending never reach the plan — handled beats viewed") {
        // A slice assigned mid-walk was decided by that act; confirming the
        // remainder must not re-assign it.
        let s1 = seg("A", 0, 60)
        let gone = UUID()
        let plan = ReviewConfirm.plan(viewed: [s1.id, gone], pending: [s1],
                                      sessions: [], bar: 0.9, score: scorer)
        try expectEq(plan.confirmedCount, 1)
        try expect(plan.unresolved.isEmpty)
    }

    c.check("empty viewed set plans nothing — the confirm button has nothing to do") {
        let s1 = seg("A", 0, 60)
        let plan = ReviewConfirm.plan(viewed: [], pending: [s1],
                                      sessions: [], bar: 0.9, score: scorer)
        try expect(plan.assignments.isEmpty)
        try expect(plan.unresolved.isEmpty)
    }

    c.check("session stamps take the retro-lift gate: unpushed, below-bar, overlapping — nothing else") {
        let s1 = seg("A", 0, 600)
        let overlapping = session(taskB, 0, 300, certainty: 0.5)
        let pushed = session(taskB, 300, 400, certainty: 0.5, pushed: true)
        let confident = session(taskB, 400, 500, certainty: 0.95)
        let elsewhere = session(taskB, 700, 800, certainty: 0.5)
        let plan = ReviewConfirm.plan(
            viewed: [s1.id], pending: [s1],
            sessions: [overlapping, pushed, confident, elsewhere],
            bar: 0.9, score: scorer)
        let stamps = plan.assignments[0].sessionStamps
        try expectEq(stamps.map(\.id), [overlapping.id],
                     "posted time and confident sessions never move off a confirm")
        // The stamp carries the session's PRIOR state — the undo payload.
        try expectEq(stamps[0].task, taskB)
        try expectEq(stamps[0].certainty, 0.5)
    }

    c.check("a .doNotTrack read clears the slice but stamps no session — there is no task to carry") {
        let s1 = seg("DNT", 0, 60)
        let under = session(taskA, 0, 60, certainty: 0.4)
        let plan = ReviewConfirm.plan(viewed: [s1.id], pending: [s1],
                                      sessions: [under], bar: 0.9, score: scorer)
        try expectEq(plan.assignments.map(\.target), [.doNotTrack])
        try expect(plan.assignments[0].sessionStamps.isEmpty)
    }

    c.check("a session overlapping two target groups is claimed once — by the earlier group in queue order") {
        // Double-stamping would register two undo restorations for one
        // session and let the later group overwrite the earlier one's word.
        let s1 = seg("A", 0, 120), s2 = seg("B", 60, 180)
        let straddling = session(taskA, 30, 150, certainty: 0.5)
        let plan = ReviewConfirm.plan(viewed: [s1.id, s2.id], pending: [s1, s2],
                                      sessions: [straddling], bar: 0.9, score: scorer)
        try expectEq(plan.assignments[0].sessionStamps.map(\.id), [straddling.id])
        try expect(plan.assignments[1].sessionStamps.isEmpty)
    }

    c.check("the confirm stamp IS the user's word — its provenance raw sits in ContradictionRefile's userDecided set") {
        // The whole promise: a confirmed slice is never refiled, never
        // nagged, never re-lifted. That contract is the userDecided gate,
        // so the stamp must use an EXISTING raw that gate recognises — a
        // parallel "confirmed" state would silently miss every check.
        try expect(ContradictionRefile.userDecided.contains(
            ReviewConfirm.stampProvenance.sourceRaw))
        try expectEq(ReviewConfirm.stampProvenance.sourceRaw, "userAssigned")
    }
}

import Foundation
import AmbitickCore

func duplicateReconcileChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func entry(_ id: Int, wp: Int = 5, start: Date, dur: TimeInterval = 600,
               comment: String? = nil) -> OPTimeEntry {
        OPTimeEntry(id: id, workPackageID: wp, start: start, durationSeconds: dur, comment: comment)
    }
    func session(task: TaskRef = .op(5), start: Date, opID: Int? = nil) -> Session {
        var s = Session(task: task, start: start, end: start.addingTimeInterval(600), certainty: 0.95)
        s.opTimeEntryID = opID
        return s
    }

    c.check("keeps the richest entry, deletes the rest, merges comments, re-points the journal") {
        let a = entry(1, start: t0, comment: "short")
        let b = entry(2, start: t0, comment: "a longer, richer comment")
        let s = session(start: t0, opID: 1)   // journal links to the entry we'll delete
        let actions = DuplicateReconcile.plan(entries: [a, b], sessions: [s])
        try expectEq(actions.count, 1)
        let act = actions[0]
        try expectEq(act.survivorID, 2, "richest (longest comment) survives")
        try expectEq(act.deleteIDs, [1])
        try expectEq(act.mergedComment, "a longer, richer comment; short")
        try expectEq(act.repointSessionIDs, [s.id], "the journal slice re-points to the survivor")
    }

    c.check("same duration but a different start is NOT a duplicate") {
        let a = entry(1, start: t0)
        let b = entry(2, start: t0.addingTimeInterval(120))   // 2 min later
        let actions = DuplicateReconcile.plan(
            entries: [a, b], sessions: [session(start: t0), session(start: t0.addingTimeInterval(120))])
        try expectEq(actions.count, 0)
    }

    c.check("a group with no matching journal slice is never touched (could be hand-entered)") {
        let a = entry(1, wp: 9, start: t0)
        let b = entry(2, wp: 9, start: t0)
        // sessions exist, but none for wp 9 at this minute and none linked.
        let actions = DuplicateReconcile.plan(entries: [a, b], sessions: [session(start: t0)])
        try expectEq(actions.count, 0)
    }

    c.check("richest falls back to longest, then lowest id; no comment merge when none") {
        let a = entry(1, start: t0, dur: 600)
        let b = entry(2, start: t0, dur: 1800)   // longer → survives
        let actions = DuplicateReconcile.plan(entries: [a, b], sessions: [session(start: t0)])
        try expectEq(actions.count, 1)
        try expectEq(actions[0].survivorID, 2)
        try expectEq(actions[0].deleteIDs, [1])
        try expectNil(actions[0].mergedComment, "no comments → nothing to fold")
    }
}

import Foundation
import timeandeyeCore

func duplicateReconcileChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func entry(_ id: Int, wp: Int = 5, start: Date, dur: TimeInterval = 600,
               comment: String? = nil) -> RemoteTimeEntry {
        RemoteTimeEntry(id: String(id), taskID: String(wp), start: start,
                        durationSeconds: dur, comment: comment)
    }
    func session(task: TaskRef = .op(5), start: Date, opID: Int? = nil) -> Session {
        var s = Session(task: task, start: start, end: start.addingTimeInterval(600), certainty: 0.95)
        s.opTimeEntryID = opID.map(String.init)
        return s
    }

    c.check("keeps the richest entry, deletes the rest, merges comments, re-points the journal") {
        let a = entry(1, start: t0, comment: "short")
        let b = entry(2, start: t0, comment: "a longer, richer comment")
        let s = session(start: t0, opID: 1)   // journal links to the entry we'll delete
        let actions = DuplicateReconcile.plan(entries: [a, b], sessions: [s])
        try expectEq(actions.count, 1)
        let act = actions[0]
        try expectEq(act.survivorID, "2", "richest (longest comment) survives")
        try expectEq(act.deleteIDs, ["1"])
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

    c.check("different durations at the same instant are NOT duplicates") {
        let a = entry(1, start: t0, dur: 600)
        let b = entry(2, start: t0, dur: 1800)   // different length → a separate log
        let actions = DuplicateReconcile.plan(
            entries: [a, b],
            sessions: [session(start: t0), session(start: t0)])
        try expectEq(actions.count, 0)
    }

    c.check("never deletes below the journal's real count (two real slices → no action)") {
        // The safety rail when OP doesn't report start times: the journal decides
        // how many entries are real. Two real slices → both kept, nothing deleted.
        let a = entry(1, start: t0, comment: "x")
        let b = entry(2, start: t0, comment: "y")
        let actions = DuplicateReconcile.plan(
            entries: [a, b],
            sessions: [session(start: t0, opID: 1), session(start: t0, opID: 2)])
        try expectEq(actions.count, 0, "2 entries, 2 journal slices → not duplicates")
    }

    c.check("deletes only the excess over the journal count") {
        // Three OP entries but the journal knows of two → delete exactly one.
        let a = entry(1, start: t0, comment: "aaa")
        let b = entry(2, start: t0, comment: "bb")
        let cc = entry(3, start: t0, comment: "c")
        let actions = DuplicateReconcile.plan(
            entries: [a, b, cc],
            sessions: [session(start: t0, opID: 1), session(start: t0, opID: 2)])
        try expectEq(actions.count, 1)
        try expectEq(actions[0].deleteIDs.count, 1, "3 entries − 2 real = 1 deleted")
        try expectEq(actions[0].deleteIDs, ["3"], "the least-rich (shortest comment) goes")
    }

    // MARK: - Undo (the reconcile journal). The duplicates are DELETED at the
    // backend, so undo can't just restore pointers — the old ids are dead and
    // later edits would PATCH a 404. The plan snapshots everything needed to
    // re-CREATE the entries verbatim and re-point each slice at its entry's
    // FRESH id; it must be taken BEFORE the apply mutates anything.

    c.check("undoPlan snapshots the deleted entries verbatim, the pre-merge comment and each slice's old pointer") {
        let survivor = entry(2, start: t0, comment: "a longer, richer comment")
        let doomed = entry(1, start: t0, comment: "short")
        let s = session(start: t0, opID: 1)
        let action = DuplicateReconcile.plan(entries: [doomed, survivor], sessions: [s])[0]

        let plan = DuplicateReconcile.undoPlan(for: action, sessions: [s])
        try expectEq(plan.survivorID, "2")
        try expectEq(plan.recreate, [doomed],
                     "the doomed entry is snapshotted whole — comment, start, length")
        try expectEq(plan.restoreSurvivorComment, "a longer, richer comment",
                     "the survivor's PRE-merge comment, not the folded one")
        try expectEq(plan.priorEntryIDBySession, [s.id: "1"],
                     "the slice remembers WHICH deleted entry it pointed at")
    }

    c.check("undoPlan: a comment-less survivor restores to empty; an untouched comment restores nothing") {
        // A merge onto a survivor that had NO comment: undo must actively
        // clear it back to empty, not leave the folded text behind. plan()
        // can't produce this shape today (the survivor is always the
        // comment-richest of its group), so undoPlan pins the defensive
        // contract against a hand-built action.
        let bare = entry(2, start: t0)
        let doomed = entry(1, start: t0, comment: "short")
        let s = session(start: t0, opID: 1)
        let merged = ReconcileAction(
            taskID: "5", start: t0, survivorID: "2", deleteIDs: ["1"],
            entries: [doomed, bare], mergedComment: "short",
            repointSessionIDs: [s.id], label: "hand-built")
        try expectEq(DuplicateReconcile.undoPlan(for: merged, sessions: [s])
            .restoreSurvivorComment, "", "empty restores the comment-less survivor")

        // Identical comments fold to the survivor's own text → the apply
        // never touches it → undo must not either (nil, not a rewrite).
        let twinA = entry(1, start: t0, comment: "same")
        let twinB = entry(2, start: t0, comment: "same")
        let untouched = DuplicateReconcile.plan(entries: [twinA, twinB],
                                                sessions: [session(start: t0, opID: 1)])[0]
        try expectNil(untouched.mergedComment, "precondition: no comment change")
        try expectNil(DuplicateReconcile.undoPlan(for: untouched, sessions: [session(start: t0, opID: 1)])
            .restoreSurvivorComment)
    }

    c.check("apply + undo round-trip: entries re-created whole, survivor comment back, slices re-pointed at the FRESH ids") {
        // The mechanics AppController.applyReconcile and its registered undo
        // perform, replayed purely against dictionary state (the house
        // pattern for controller flows — no AppController in checks).
        let survivor = entry(2, start: t0, comment: "a rich comment")
        let doomed = entry(1, start: t0, comment: "short")
        var s = session(start: t0, opID: 1)
        let action = DuplicateReconcile.plan(entries: [doomed, survivor], sessions: [s])[0]
        var backendEntries = ["1": doomed, "2": survivor]

        // Snapshot FIRST (as the controller must), then apply.
        let plan = DuplicateReconcile.undoPlan(for: action, sessions: [s])
        if let merged = action.mergedComment { backendEntries["2"]?.comment = merged }
        for id in action.deleteIDs { backendEntries[id] = nil }
        s.opTimeEntryID = action.survivorID
        try expectEq(backendEntries["2"]?.comment, "a rich comment; short")
        try expectNil(backendEntries["1"], "the duplicate is gone at the backend")

        // Undo: re-create with FRESH backend-assigned ids, restore the
        // survivor's comment, re-point each slice via old id → fresh id.
        var freshIDs: [RemoteEntryID: RemoteEntryID] = [:]
        for e in plan.recreate {
            var recreated = e
            recreated.id = "fresh-\(e.id)"
            backendEntries[recreated.id] = recreated
            freshIDs[e.id] = recreated.id
        }
        if let restore = plan.restoreSurvivorComment {
            backendEntries[plan.survivorID]?.comment = restore.isEmpty ? nil : restore
        }
        if let old = plan.priorEntryIDBySession[s.id], let fresh = freshIDs[old] {
            s.opTimeEntryID = fresh
        }
        try expectEq(backendEntries["2"]?.comment, "a rich comment", "the fold is unwound")
        let back = try unwrap(backendEntries["fresh-1"], "the duplicate exists again")
        try expectEq(back.comment, "short")
        try expectEq(back.durationSeconds, doomed.durationSeconds)
        try expectEq(back.start, doomed.start)
        try expectEq(s.opTimeEntryID, "fresh-1",
                     "the slice points at a LIVE entry — future edits PATCH something real")
    }
}

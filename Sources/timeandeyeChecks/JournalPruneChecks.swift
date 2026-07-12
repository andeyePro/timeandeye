import Foundation
import timeandeyeCore

func journalPruneChecks(_ c: Checks) {
    // Fixed UTC calendar so day boundaries are deterministic.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)          // 2025-06-15
    func daysAgo(_ d: Double, _ offset: TimeInterval = 0) -> Date {
        cal.startOfDay(for: now.addingTimeInterval(-d * 86_400)).addingTimeInterval(offset)
    }
    func s(_ task: TaskRef, start: Date, minutes: Double, pushed: Bool = true,
           certainty: Double = 0.9, comment: String? = nil) -> Session {
        Session(task: task, start: start, end: start.addingTimeInterval(minutes * 60),
                certainty: certainty, pushedToOP: pushed, comment: comment)
    }

    c.check("old same-day same-task slices roll up: duration summed, comments folded, duration-weighted mean certainty") {
        let a = s(.op(1), start: daysAgo(800, 9 * 3600), minutes: 30,
                  certainty: 0.8, comment: "morning")
        let b = s(.op(1), start: daysAgo(800, 14 * 3600), minutes: 45,
                  certainty: 0.95, comment: "afternoon")
        let plan = JournalPrune.plan(sessions: [b, a], olderThanDays: 730,
                                     now: now, calendar: cal)
        try expectEq(plan.create.count, 1)
        let r = plan.create[0]
        try expectEq(r.task, .op(1))
        try expectEq(r.start, a.start, "anchored at the day's first slice")
        try expectEq(r.end.timeIntervalSince(r.start), 75 * 60, "durations summed")
        // Duration-weighted mean (spec §Folds), not max: (0.8·30 + 0.95·45)/75.
        try expectClose(r.certainty, (0.8 * 30 + 0.95 * 45) / 75)
        try expect(r.pushedToOP)
        try expectNil(r.opTimeEntryID, "ancient rollups drop per-entry backend ids")
        try expectEq(r.comment, "morning; afternoon (consolidated 2 slices)")
        try expectEq(Set(plan.deleteIDs), Set([a.id, b.id]))
    }

    c.check("rollup id is DETERMINISTIC: two devices pruning the same group mint the identical rollup (C16)") {
        // Same member sessions, different array order (arrival order differs
        // across devices) — the created rollup must carry the SAME id, so the
        // two rollups LWW-merge as one record instead of double-counting the
        // day forever.
        let a = s(.op(1), start: daysAgo(800, 9 * 3600), minutes: 30)
        let b = s(.op(1), start: daysAgo(800, 14 * 3600), minutes: 45)
        let planA = JournalPrune.plan(sessions: [a, b], olderThanDays: 730,
                                      now: now, calendar: cal)
        let planB = JournalPrune.plan(sessions: [b, a], olderThanDays: 730,
                                      now: now, calendar: cal)
        try expectEq(planA.create.count, 1)
        try expectEq(planA.create.map(\.id), planB.create.map(\.id),
                     "order-independent deterministic rollup ids")
        // And a DIFFERENT group yields a different id.
        let c2 = s(.op(2), start: daysAgo(800, 9 * 3600), minutes: 30)
        let d2 = s(.op(2), start: daysAgo(800, 14 * 3600), minutes: 45)
        let planC = JournalPrune.plan(sessions: [c2, d2], olderThanDays: 730,
                                      now: now, calendar: cal)
        try expect(planC.create[0].id != planA.create[0].id, "distinct groups, distinct ids")
    }

    c.check("groups split by day AND task; singles left untouched") {
        let d1t1a = s(.op(1), start: daysAgo(800, 3600), minutes: 10)
        let d1t1b = s(.op(1), start: daysAgo(800, 7200), minutes: 10)
        let d1t2 = s(.op(2), start: daysAgo(800, 3600), minutes: 10)     // single
        let d2t1 = s(.op(1), start: daysAgo(799, 3600), minutes: 10)     // single, next day
        let plan = JournalPrune.plan(sessions: [d1t1a, d1t1b, d1t2, d2t1],
                                     olderThanDays: 730, now: now, calendar: cal)
        try expectEq(plan.create.count, 1, "only the 2-slice group consolidates")
        try expect(!plan.deleteIDs.contains(d1t2.id))
        try expect(!plan.deleteIDs.contains(d2t1.id))
    }

    c.check("recent slices and unpushed remote slices are NEVER touched") {
        let recent = s(.op(1), start: daysAgo(10, 3600), minutes: 10)
        let recent2 = s(.op(1), start: daysAgo(10, 7200), minutes: 10)
        let owed = s(.op(2), start: daysAgo(800, 3600), minutes: 10, pushed: false)
        let owed2 = s(.op(2), start: daysAgo(800, 7200), minutes: 10, pushed: false)
        let plan = JournalPrune.plan(sessions: [recent, recent2, owed, owed2],
                                     olderThanDays: 730, now: now, calendar: cal)
        try expect(plan.isEmpty, "recent data + unpushed backend debts are sacred")
    }

    c.check("local tasks consolidate regardless of pushed flag") {
        let ref = TaskRef.local(UUID())
        let a = s(ref, start: daysAgo(800, 3600), minutes: 20, pushed: false)
        let b = s(ref, start: daysAgo(800, 7200), minutes: 25, pushed: false)
        let plan = JournalPrune.plan(sessions: [a, b], olderThanDays: 730,
                                     now: now, calendar: cal)
        try expectEq(plan.create.count, 1)
        try expectEq(plan.create[0].end.timeIntervalSince(plan.create[0].start), 45 * 60)
    }

    c.check("cutoff is a DAY boundary: a slice ending on/after the cutoff day stays") {
        // Starts 30 min INTO the cutoff day → end >= cutoff → untouchable,
        // even alongside an older consolidatable group.
        let boundary = s(.op(1), start: daysAgo(730, 1800), minutes: 20)
        let old = s(.op(1), start: daysAgo(731, 3600), minutes: 20)
        let old2 = s(.op(1), start: daysAgo(731, 7200), minutes: 20)
        let plan = JournalPrune.plan(sessions: [boundary, old, old2],
                                     olderThanDays: 730, now: now, calendar: cal)
        try expect(!plan.deleteIDs.contains(boundary.id))
        try expectEq(plan.create.count, 1, "the two genuinely-old slices still roll up")
    }

    c.check("totals survive exactly: sum of rollup durations == sum of the originals, per task per day") {
        let t1a = s(.op(1), start: daysAgo(800, 3600), minutes: 20)
        let t1b = s(.op(1), start: daysAgo(800, 7200), minutes: 35)
        let t2a = s(.op(2), start: daysAgo(800, 3600), minutes: 15)
        let t2b = s(.op(2), start: daysAgo(800, 10_800), minutes: 50)
        let originalTotal = [t1a, t1b, t2a, t2b].reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let plan = JournalPrune.plan(sessions: [t1a, t1b, t2a, t2b], olderThanDays: 730,
                                     now: now, calendar: cal)
        let rollupTotal = plan.create.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        try expectEq(rollupTotal, originalTotal, "not a second of tracked time invented or lost")
    }

    c.check("consolidation is idempotent: re-running the plan over its own output changes nothing further") {
        let a = s(.op(1), start: daysAgo(800, 9 * 3600), minutes: 30, comment: "morning")
        let b = s(.op(1), start: daysAgo(800, 14 * 3600), minutes: 45, comment: "afternoon")
        let untouched = s(.op(2), start: daysAgo(800, 3600), minutes: 10)   // single, never rolled
        let first = JournalPrune.plan(sessions: [a, b, untouched], olderThanDays: 730,
                                      now: now, calendar: cal)
        try expect(!first.isEmpty)
        // Apply the plan by hand: drop the consolidated originals, add the rollup.
        let deleted = Set(first.deleteIDs)
        let afterApply = [a, b, untouched].filter { !deleted.contains($0.id) } + first.create
        let second = JournalPrune.plan(sessions: afterApply, olderThanDays: 730,
                                       now: now, calendar: cal)
        try expect(second.isEmpty, "a lone rollup is a group of 1 — never re-consolidated")
    }

    c.check("comment fold is deduplicated and capped: repeats collapse, long runs truncate with a count") {
        let base = daysAgo(800, 3600)
        var slices: [Session] = []
        for i in 0..<14 {
            slices.append(s(.op(1), start: base.addingTimeInterval(Double(i) * 60), minutes: 1,
                            comment: i < 3 ? "same note" : "note \(i)"))   // first 3 repeat verbatim
        }
        let plan = JournalPrune.plan(sessions: slices, olderThanDays: 730, now: now, calendar: cal)
        try expectEq(plan.create.count, 1)
        let comment = try unwrap(plan.create[0].comment)
        try expectEq(comment.components(separatedBy: "same note").count - 1, 1,
                     "the 3 identical comments collapse to ONE occurrence")
        try expect(comment.contains("+"), "beyond the cap, the rest fold into a '+N more' count")
        try expect(comment.hasSuffix("(consolidated 14 slices)"))
    }

    // MARK: - (c) Hard-cap prune

    c.check("hard cap is a no-op when already under the ceiling") {
        let a = s(.op(1), start: daysAgo(800, 3600), minutes: 20)
        let plan = JournalPrune.hardCapPlan(sessions: [a], capBytes: 1_000_000)
        try expect(plan.isEmpty)
    }

    c.check("hard cap deletes the OLDEST raw slices first and stops the moment the ceiling is met") {
        let oldest = s(.op(1), start: daysAgo(800, 3600), minutes: 20, comment: "oldest")
        let middle = s(.op(1), start: daysAgo(500, 3600), minutes: 20, comment: "middle")
        let newest = s(.op(1), start: daysAgo(10, 3600), minutes: 20, comment: "newest")
        // Derived from the REAL encoded sizes (never assume they're equal
        // just because the durations match) — set the cap to exactly what's
        // left once `oldest` alone is gone, so only it need be deleted.
        let encoder = JSONEncoder()
        let sizeOldest = try encoder.encode(oldest).count
        let total = try [oldest, middle, newest].reduce(0) { $0 + (try encoder.encode($1).count) }
        let capBytes = total - sizeOldest
        let plan = JournalPrune.hardCapPlan(sessions: [newest, middle, oldest], capBytes: capBytes)
        try expectEq(plan.deleteIDs, [oldest.id], "the single oldest slice is deleted, nothing newer touched")
        try expect(plan.create.isEmpty, "hard cap never creates rollups")
    }

    c.check("hard cap NEVER deletes a consolidation rollup, even when it is the oldest bytes") {
        let rollupID = SessionMerge.fragmentID(parent: UUID(), index: 0)
        let ancientRollup = Session(id: rollupID, task: .op(1), start: daysAgo(900, 0),
                                    end: daysAgo(900, 3600), certainty: 1, pushedToOP: true,
                                    comment: "consolidated 40 slices")
        let raw = s(.op(2), start: daysAgo(600, 3600), minutes: 20)
        // Cap tighter than the total: SOMETHING has to be deleted to comply,
        // and the rollup is both oldest AND largest — it must still survive.
        let plan = JournalPrune.hardCapPlan(sessions: [ancientRollup, raw], capBytes: 1)
        try expect(!plan.deleteIDs.contains(rollupID), "rollups are off-limits regardless of age or size")
        try expect(plan.deleteIDs.contains(raw.id), "the raw slice is the only eligible candidate")
    }
}

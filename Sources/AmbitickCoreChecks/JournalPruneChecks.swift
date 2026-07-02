import Foundation
import AmbitickCore

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

    c.check("old same-day same-task slices roll up: duration summed, comments folded, max certainty") {
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
        try expectEq(r.certainty, 0.95)
        try expect(r.pushedToOP)
        try expectNil(r.opTimeEntryID, "ancient rollups drop per-entry backend ids")
        try expectEq(r.comment, "morning; afternoon (consolidated 2 slices)")
        try expectEq(Set(plan.deleteIDs), Set([a.id, b.id]))
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
}

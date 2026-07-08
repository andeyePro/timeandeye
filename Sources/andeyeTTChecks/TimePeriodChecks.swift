import Foundation
import andeyeTTCore

func timePeriodChecks(_ c: Checks) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    c.check("today anchors on the given day") {
        let t = TimePeriod.today.range(anchor: now, now: now, calendar: cal)
        try expectEq(t.start, cal.startOfDay(for: now))
        try expectEq(t.end, cal.startOfDay(for: now).addingTimeInterval(86_400))
        // A prior anchor gives that prior day.
        let back = now.addingTimeInterval(-2 * 86_400)
        let tb = TimePeriod.today.range(anchor: back, now: now, calendar: cal)
        try expectEq(tb.start, cal.startOfDay(for: back))
    }

    c.check("last 7 days: 7-long, ends on today's weekday wherever anchored") {
        let r = TimePeriod.last7.range(anchor: now, now: now, calendar: cal)
        try expectEq(r.end, cal.startOfDay(for: now).addingTimeInterval(86_400),
                     "anchor==now → the familiar last-7-days-ending-today")
        try expectEq(r.end.timeIntervalSince(r.start), 7 * 86_400)
        // Anchor a few days back: still 7 long, still ends on today's weekday.
        let back = now.addingTimeInterval(-3 * 86_400)
        let rb = TimePeriod.last7.range(anchor: back, now: now, calendar: cal)
        try expectEq(rb.end.timeIntervalSince(rb.start), 7 * 86_400)
        try expectEq(cal.component(.weekday, from: rb.end.addingTimeInterval(-1)),
                     cal.component(.weekday, from: now), "end day matches today's weekday")
    }

    c.check("week / month anchor on the containing week / month") {
        let w = TimePeriod.thisWeek.range(anchor: now, now: now, calendar: cal)
        try expectEq(w.start, cal.dateInterval(of: .weekOfYear, for: now)!.start)
        try expectEq(w.end.timeIntervalSince(w.start), 7 * 86_400)
        let m = TimePeriod.thisMonth.range(anchor: now, now: now, calendar: cal)
        try expectEq(m.start, cal.dateInterval(of: .month, for: now)!.start)
        try expect(m.end > m.start)
        // A prior-month anchor gives that month.
        let prior = cal.date(byAdding: .month, value: -2, to: now)!
        let mp = TimePeriod.thisMonth.range(anchor: prior, now: now, calendar: cal)
        try expectEq(mp.start, cal.dateInterval(of: .month, for: prior)!.start)
    }

    c.check("DST day lengths: 'today' spans 25h on clocks-back Sunday (London), not a raw 86400 (C15)") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        // 2026-10-25: BST -> GMT, the 25-hour day.
        let comps = DateComponents(year: 2026, month: 10, day: 25, hour: 12)
        let anchor = cal.date(from: comps)!
        let (start, end) = TimePeriod.today.range(anchor: anchor, now: anchor, calendar: cal)
        try expectEq(end.timeIntervalSince(start), 25 * 3600,
                     "calendar day, not +86400 — an hour of sessions was landing in the wrong period")
        let (wStart, wEnd) = TimePeriod.thisWeek.range(anchor: anchor, now: anchor, calendar: cal)
        try expectEq(wEnd.timeIntervalSince(wStart), 7 * 86_400 + 3_600,
                     "the week containing the change is 169h long")
    }

    c.check("matching identifies a preset-equal selection, nil for custom") {
        // A selection equal to this-week's range re-lights the Week preset.
        let w = TimePeriod.thisWeek.range(anchor: now, now: now, calendar: cal)
        try expectEq(TimePeriod.matching(start: w.start, endExclusive: w.end,
                                         now: now, calendar: cal), .thisWeek)
        // A single arbitrary day in the past matches nothing → custom.
        let d = cal.startOfDay(for: now.addingTimeInterval(-10 * 86_400))
        try expectNil(TimePeriod.matching(start: d, endExclusive: d.addingTimeInterval(86_400),
                                          now: now, calendar: cal))
    }
}

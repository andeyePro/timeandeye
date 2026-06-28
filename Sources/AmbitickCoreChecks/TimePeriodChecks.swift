import Foundation
import AmbitickCore

func timePeriodChecks(_ c: Checks) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    c.check("today / yesterday anchor on the given day") {
        let t = TimePeriod.today.range(anchor: now, now: now, calendar: cal)
        try expectEq(t.start, cal.startOfDay(for: now))
        try expectEq(t.end, cal.startOfDay(for: now).addingTimeInterval(86_400))
        let y = TimePeriod.yesterday.range(anchor: now, now: now, calendar: cal)
        try expectEq(y.end, cal.startOfDay(for: now))
        try expectEq(y.start, cal.startOfDay(for: now).addingTimeInterval(-86_400))
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
}

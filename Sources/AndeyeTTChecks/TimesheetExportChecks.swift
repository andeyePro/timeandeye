import Foundation
import AndeyeTTCore

func timesheetExportChecks(_ c: Checks) {
    // Fixed UTC calendar so the expected strings are platform/timezone-stable.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15 15:06:40 UTC

    func names(_ ref: TaskRef) -> (task: String, project: String?) {
        switch ref {
        case .op(1): return ("Ambitick build", "Ambitick")
        case .op(2): return ("Insurance, renewal \"B\"", "Admin")
        default: return ("Chess", nil)
        }
    }

    c.check("csv: header, ordering, quoting, duration") {
        let sessions = [
            Session(task: .op(2), start: t0.addingTimeInterval(4000),
                    end: t0.addingTimeInterval(5800), certainty: 1, comment: "call, then email"),
            Session(task: .op(1), start: t0, end: t0.addingTimeInterval(5400),
                    certainty: 1, comment: nil),
        ]
        let csv = TimesheetExport.csv(sessions: sessions, names: names, calendar: cal)
        let lines = csv.split(separator: "\n").map(String.init)
        try expectEq(lines[0], "date,start,end,duration,project,task,comment")
        try expectEq(lines[1], "2025-06-15,15:06,16:36,1:30,Ambitick,Ambitick build,",
                     "oldest first despite input order")
        try expectEq(lines[2],
                     "2025-06-15,16:13,16:43,0:30,Admin,\"Insurance, renewal \"\"B\"\"\",\"call, then email\"",
                     "comma + quote fields are RFC-4180 quoted")
        try expectEq(lines.count, 3)
    }

    c.check("markdown: day grouping, per-day and grand totals, project prefix") {
        let sessions = [
            Session(task: .op(1), start: t0, end: t0.addingTimeInterval(3600), certainty: 1),
            Session(task: .local(UUID()), start: t0.addingTimeInterval(90_000),
                    end: t0.addingTimeInterval(93_600), certainty: 1, comment: "evening game"),
        ]
        let md = TimesheetExport.markdown(sessions: sessions, names: names, calendar: cal)
        try expect(md.contains("## 2025-06-15"), "first day heading")
        try expect(md.contains("## 2025-06-16"), "second day heading")
        try expect(md.contains("- 15:06–16:06 (1:00) — Ambitick / Ambitick build"))
        try expect(md.contains("- 16:06–17:06 (1:00) — Chess — evening game"),
                   "nil project renders without the project prefix")
        try expectEq(md.components(separatedBy: "Day total: 1:00").count, 3,
                     "one day-total per day")
        try expect(md.contains("**Total: 2:00**"), "grand total")
    }

    c.check("markdown: empty period says so") {
        try expectEq(TimesheetExport.markdown(sessions: [], names: names, calendar: cal),
                     "No tracked time in this period.\n")
    }

    c.check("duration text: zero-pads minutes, hours unbounded") {
        try expectEq(TimesheetExport.durationText(0), "0:00")
        try expectEq(TimesheetExport.durationText(59 * 60), "0:59")
        try expectEq(TimesheetExport.durationText(26 * 3600 + 5 * 60), "26:05")
    }
}

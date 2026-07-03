import Foundation

/// Standalone timesheet export: the journal rendered as CSV or Markdown, so a
/// backend-less user (or anyone invoicing outside their PM tool) can get their
/// time OUT of andeye. Pure and deterministic — the caller supplies the
/// sessions (already filtered to the wanted period, minus the live checkpoint
/// row) and a task-name resolver.
public enum TimesheetExport {
    /// Task + project display names for a ref (project nil → blank column).
    public typealias NameResolver = (TaskRef) -> (task: String, project: String?)

    /// One line per session, oldest first:
    /// `date,start,end,duration,project,task,comment` with RFC-4180 quoting.
    public static func csv(sessions: [Session], names: NameResolver,
                           calendar: Calendar = .current) -> String {
        var out = ["date,start,end,duration,project,task,comment"]
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let n = names(s.task)
            out.append([
                dayFormatter(calendar).string(from: s.start),
                timeFormatter(calendar).string(from: s.start),
                timeFormatter(calendar).string(from: s.end),
                durationText(s.end.timeIntervalSince(s.start)),
                csvField(n.project ?? ""),
                csvField(n.task),
                csvField(s.comment ?? ""),
            ].joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Day-grouped Markdown with per-day and grand totals — the human-readable
    /// companion to the CSV (paste into an email / invoice note).
    public static func markdown(sessions: [Session], names: NameResolver,
                                calendar: Calendar = .current) -> String {
        let sorted = sessions.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return "No tracked time in this period.\n" }
        var out: [String] = []
        var currentDay = ""
        var dayTotal: TimeInterval = 0
        var grandTotal: TimeInterval = 0
        func flushDayTotal() {
            if !currentDay.isEmpty {
                out.append("")
                out.append("Day total: \(durationText(dayTotal))")
            }
        }
        for s in sorted {
            let day = dayFormatter(calendar).string(from: s.start)
            if day != currentDay {
                flushDayTotal()
                if !currentDay.isEmpty { out.append("") }
                out.append("## \(day)")
                out.append("")
                currentDay = day
                dayTotal = 0
            }
            let n = names(s.task)
            let dur = s.end.timeIntervalSince(s.start)
            dayTotal += dur
            grandTotal += dur
            var line = "- \(timeFormatter(calendar).string(from: s.start))–"
                + "\(timeFormatter(calendar).string(from: s.end)) "
                + "(\(durationText(dur))) — "
            if let p = n.project, !p.isEmpty { line += "\(p) / " }
            line += n.task
            if let c = s.comment, !c.isEmpty { line += " — \(c)" }
            out.append(line)
        }
        flushDayTotal()
        out.append("")
        out.append("**Total: \(durationText(grandTotal))**")
        return out.joined(separator: "\n") + "\n"
    }

    /// "H:MM" (matches the menu-bar clock's vocabulary, no seconds).
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 3600):" + String(format: "%02d", (total % 3600) / 60)
    }

    /// RFC 4180: quote when the field holds a comma, quote or newline;
    /// double embedded quotes.
    static func csvField(_ raw: String) -> String {
        if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
            return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return raw
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}

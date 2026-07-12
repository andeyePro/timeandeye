import Foundation

/// One task's learned + pinned email rules, for the Rules Ledger (2026-07-03
/// context-rules spec §5.3 — list + provenance + delete + bulk forget +
/// export; search-by-last-5-matches is still later polish, §6).
package struct RulesLedgerGroup: Equatable, Sendable {
    package var target: TaskRef
    package var rows: [EmailRule]

    package init(target: TaskRef, rows: [EmailRule]) {
        self.target = target
        self.rows = rows
    }
}

package enum RulesLedger {
    /// Group rules by target task, sorted pinned-first then by how often each
    /// has fired (most-active first) then newest-first — the rules most worth
    /// a glance sort to the top of their group. Groups sort by task name (via
    /// `nameOf`, case-insensitive) so the ledger reads like a contact list,
    /// not insertion order. `search` matches either the rule's value or its
    /// task's name.
    package static func grouped(_ rules: [EmailRule], nameOf: (TaskRef) -> String,
                               search: String = "") -> [RulesLedgerGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? rules : rules.filter {
            $0.value.localizedCaseInsensitiveContains(query)
                || nameOf($0.target).localizedCaseInsensitiveContains(query)
        }
        let byTask = Dictionary(grouping: filtered, by: \.target)
        return byTask.map { target, rows in
            RulesLedgerGroup(target: target, rows: rows.sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }
                return $0.createdAt > $1.createdAt
            })
        }.sorted { nameOf($0.target).localizedCaseInsensitiveCompare(nameOf($1.target)) == .orderedAscending }
    }

    /// Plain-text dump of every rule for the ledger's "Copy rules" button —
    /// grouped exactly like the list (task name as heading), each rule's
    /// grain, value, provenance and fire count on its own line. Pure and
    /// deterministic (mirrors `TimesheetExport`'s style) so it's checkable
    /// without a clipboard.
    package static func exportText(_ rules: [EmailRule], nameOf: (TaskRef) -> String,
                                  calendar: Calendar = .current) -> String {
        let groups = grouped(rules, nameOf: nameOf)
        guard !groups.isEmpty else { return "No email rules learned or pinned yet.\n" }
        var out: [String] = []
        for group in groups {
            out.append(nameOf(group.target))
            for rule in group.rows {
                out.append("  " + exportLine(rule, calendar: calendar))
            }
            out.append("")
        }
        out.removeLast()   // drop the trailing blank separator
        return out.joined(separator: "\n") + "\n"
    }

    private static func exportLine(_ rule: EmailRule, calendar: Calendar) -> String {
        var parts = ["\(rule.level.label): \(rule.value.isEmpty ? "any mail" : rule.value)"]
        parts.append(rule.pinned ? "pinned" : "learned")
        if rule.createdAt != .distantPast {
            parts.append(exportDayFormatter(calendar).string(from: rule.createdAt))
        }
        parts.append("fired \(rule.fireCount)×")
        if let last = rule.lastFired {
            parts.append("last \(exportDayFormatter(calendar).string(from: last))")
        }
        return parts.joined(separator: " · ")
    }

    private static func exportDayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}

/// One task's learned + pinned SITE rules — the ledger's "Sites" segment
/// (2026-07-09 site-recipes spec §6), duplicated in the small-function style
/// the calendar spec chose rather than a premature shared generic; the
/// three-domain protocol refactor is a dedicated later pass.
package struct SiteRulesLedgerGroup: Equatable, Sendable {
    package var target: TaskRef
    package var rows: [SiteRule]

    package init(target: TaskRef, rows: [SiteRule]) {
        self.target = target
        self.rows = rows
    }
}

package enum SiteRulesLedger {
    /// Same grouping/sorting contract as `RulesLedger.grouped`: by task,
    /// pinned-first then most-fired then newest within a group; groups by
    /// task name. `search` matches the rule's value, its grain label
    /// ("GitHub repository") or its task's name.
    package static func grouped(_ rules: [SiteRule], nameOf: (TaskRef) -> String,
                               search: String = "") -> [SiteRulesLedgerGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? rules : rules.filter {
            $0.value.localizedCaseInsensitiveContains(query)
                || $0.grainLabel.localizedCaseInsensitiveContains(query)
                || nameOf($0.target).localizedCaseInsensitiveContains(query)
        }
        let byTask = Dictionary(grouping: filtered, by: \.target)
        return byTask.map { target, rows in
            SiteRulesLedgerGroup(target: target, rows: rows.sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }
                return $0.createdAt > $1.createdAt
            })
        }.sorted { nameOf($0.target).localizedCaseInsensitiveCompare(nameOf($1.target)) == .orderedAscending }
    }

    /// Plain-text dump for the ledger's "Copy rules" on the Sites segment —
    /// `RulesLedger.exportText`'s exact shape, site-grain captions.
    package static func exportText(_ rules: [SiteRule], nameOf: (TaskRef) -> String,
                                  calendar: Calendar = .current) -> String {
        let groups = grouped(rules, nameOf: nameOf)
        guard !groups.isEmpty else { return "No site rules learned or pinned yet.\n" }
        var out: [String] = []
        for group in groups {
            out.append(nameOf(group.target))
            for rule in group.rows {
                out.append("  " + exportLine(rule, calendar: calendar))
            }
            out.append("")
        }
        out.removeLast()
        return out.joined(separator: "\n") + "\n"
    }

    private static func exportLine(_ rule: SiteRule, calendar: Calendar) -> String {
        var parts = ["\(rule.grainLabel): \(rule.value)"]
        parts.append(rule.pinned ? "pinned" : "learned")
        if rule.createdAt != .distantPast {
            parts.append(exportDayFormatter(calendar).string(from: rule.createdAt))
        }
        parts.append("fired \(rule.fireCount)×")
        if let last = rule.lastFired {
            parts.append("last \(exportDayFormatter(calendar).string(from: last))")
        }
        return parts.joined(separator: " · ")
    }

    private static func exportDayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}

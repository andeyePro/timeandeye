import Foundation

/// One task's learned + pinned email rules, for the Rules Ledger (2026-07-03
/// context-rules spec §5.3 — this phase is scoped to list + provenance +
/// delete; search-by-last-5-matches, bulk actions and export are later
/// polish, §6).
public struct RulesLedgerGroup: Equatable, Sendable {
    public var target: TaskRef
    public var rows: [EmailRule]

    public init(target: TaskRef, rows: [EmailRule]) {
        self.target = target
        self.rows = rows
    }
}

public enum RulesLedger {
    /// Group rules by target task, sorted pinned-first then by how often each
    /// has fired (most-active first) then newest-first — the rules most worth
    /// a glance sort to the top of their group. Groups sort by task name (via
    /// `nameOf`, case-insensitive) so the ledger reads like a contact list,
    /// not insertion order. `search` matches either the rule's value or its
    /// task's name.
    public static func grouped(_ rules: [EmailRule], nameOf: (TaskRef) -> String,
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
}

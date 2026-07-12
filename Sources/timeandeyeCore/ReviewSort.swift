import Foundation

/// How the Review drawer orders its stacks (Martin, 2026-07-09, clearing a
/// large backlog: "sort by fields at the top: time, duration" so a range
/// select can sweep "everything underneath whatever duration or before
/// whatever date they don't care about").
///
/// Both time orders key on the stack's LAST activity, not its first: the
/// sweep guarantee is "everything above the cutoff row is entirely before
/// the date I stopped caring" — with `last` ascending, every stack above
/// the cutoff has NO activity after it, whereas keying on `first` would
/// rank a long-lived surface that was active five minutes ago as "old".
package enum ReviewSortOrder: String, Codable, Equatable, Sendable, CaseIterable {
    case newestFirst
    case oldestFirst
    case longestFirst
    case shortestFirst
}

package extension Array where Element == ReviewStack {
    /// The drawer's display order. Deterministic under every order: time
    /// ties break by surface id; duration ties break by recency (newest
    /// first — mid-backlog the recent stack is the one still worth eyes),
    /// then id — so a reload never visually shuffles equal rows.
    func sorted(by order: ReviewSortOrder) -> [ReviewStack] {
        sorted { a, b in
            switch order {
            case .newestFirst:
                if a.last != b.last { return a.last > b.last }
            case .oldestFirst:
                if a.last != b.last { return a.last < b.last }
            case .longestFirst:
                if a.total != b.total { return a.total > b.total }
                if a.last != b.last { return a.last > b.last }
            case .shortestFirst:
                if a.total != b.total { return a.total < b.total }
                if a.last != b.last { return a.last > b.last }
            }
            return a.id < b.id
        }
    }
}

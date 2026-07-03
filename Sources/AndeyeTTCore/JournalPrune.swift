import Foundation

/// Age-consolidation prune (iCloud quota stewardship): slices older than a
/// cutoff collapse into ONE rollup session per (day, task) — totals and
/// comments survive at ~1% of the size; second-by-second position detail is
/// what's traded away. Pure planning only: the caller applies the plan
/// through the journal (deletes become sync tombstones, creates sync
/// normally), shows it for confirmation first, and NEVER touches recent data.
public enum JournalPrune {
    public struct Plan: Equatable, Sendable {
        /// Rollup sessions to create (one per day+task with ≥2 sources, or
        /// kept-as-is singles are simply not planned at all).
        public var create: [Session]
        /// The consolidated originals to delete.
        public var deleteIDs: [UUID]
        public var isEmpty: Bool { create.isEmpty && deleteIDs.isEmpty }
    }

    /// Consolidate everything strictly older than `olderThanDays`.
    /// Rules:
    /// - Only PUSHED remote slices and local-task slices consolidate — an
    ///   unpushed remote slice still owes a backend entry and must keep its
    ///   exact identity until it pushes.
    /// - A (day, task) group of ONE stays untouched (no gain, losing its
    ///   remote-entry link would only hurt).
    /// - The rollup keeps: summed duration (anchored at the group's first
    ///   start), max certainty, folded distinct comments, pushed=true (the
    ///   sources were), and drops per-entry backend ids (ancient history —
    ///   edits that old re-push rather than PATCH).
    public static func plan(sessions: [Session], olderThanDays days: Int,
                            now: Date = Date(),
                            calendar: Calendar = .current) -> Plan {
        let cutoff = calendar.startOfDay(
            for: now.addingTimeInterval(-Double(days) * 86_400))
        var groups: [String: [Session]] = [:]
        for s in sessions where s.end < cutoff {
            guard s.pushedToOP || !s.task.isRemote else { continue }
            let day = calendar.startOfDay(for: s.start)
            groups["\(day.timeIntervalSince1970)|\(s.task.storageKey)", default: []].append(s)
        }
        var create: [Session] = []
        var deleteIDs: [UUID] = []
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { $0.start < $1.start }
            let total = sorted.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            var seen = Set<String>()
            var comments: [String] = []
            for c in sorted.compactMap(\.comment) {
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { comments.append(t) }
            }
            let note = "consolidated \(sorted.count) slices"
            let comment = comments.isEmpty ? note : comments.joined(separator: "; ") + " (\(note))"
            create.append(Session(
                task: sorted[0].task,
                start: sorted[0].start,
                end: sorted[0].start.addingTimeInterval(total),
                certainty: sorted.map(\.certainty).max() ?? 1,
                pushedToOP: true,
                comment: comment))
            deleteIDs += sorted.map(\.id)
        }
        create.sort { $0.start < $1.start }
        deleteIDs.sort { $0.uuidString < $1.uuidString }
        return Plan(create: create, deleteIDs: deleteIDs)
    }
}

import Foundation

/// Age-consolidation prune (iCloud quota stewardship): slices older than a
/// cutoff collapse into ONE rollup session per (day, task) — totals and
/// comments survive at ~1% of the size; second-by-second position detail is
/// what's traded away. Pure planning only: the caller applies the plan
/// through the journal (deletes become sync tombstones, creates sync
/// normally), shows it for confirmation first, and NEVER touches recent data.
package enum JournalPrune {
    package struct Plan: Equatable, Sendable {
        /// Rollup sessions to create (one per day+task with ≥2 sources, or
        /// kept-as-is singles are simply not planned at all).
        package var create: [Session]
        /// The consolidated originals to delete.
        package var deleteIDs: [UUID]
        package var isEmpty: Bool { create.isEmpty && deleteIDs.isEmpty }
    }

    /// Consolidate everything strictly older than `olderThanDays`.
    /// Rules:
    /// - Only PUSHED remote slices and local-task slices consolidate — an
    ///   unpushed remote slice still owes a backend entry and must keep its
    ///   exact identity until it pushes.
    /// - A (day, task) group of ONE stays untouched (no gain, losing its
    ///   remote-entry link would only hurt).
    /// - The rollup keeps: summed duration (anchored at the group's first
    ///   start), the DURATION-WEIGHTED MEAN certainty (spec §Folds: every
    ///   many-to-one fold blends confidence by time — not max, not min),
    ///   folded distinct comments, pushed=true (the sources were), and drops
    ///   per-entry backend ids (ancient history — edits that old re-push
    ///   rather than PATCH).
    package static func plan(sessions: [Session], olderThanDays days: Int,
                            now: Date = Date(),
                            calendar: Calendar = .current) -> Plan {
        // Calendar day-subtraction (DST-safe), NOT raw seconds: near midnight
        // with a DST transition in the window, raw arithmetic could shift the
        // cutoff day by one, changing which day's sessions become eligible.
        let cutoff = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -days, to: now) ?? now)
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
            // Capped sensibly: a day+task group is normally a handful of
            // slices, but years of daily switching could otherwise fold into
            // one unreadably long row — keep the first 10 distinct comments
            // (chronological, same order as `comments`) and count the rest.
            let maxComments = 10
            let shown = comments.count > maxComments ? Array(comments.prefix(maxComments))
                + ["+\(comments.count - maxComments) more"] : comments
            let note = "consolidated \(sorted.count) slices"
            let comment = shown.isEmpty ? note : shown.joined(separator: "; ") + " (\(note))"
            // DETERMINISTIC rollup id (C16): derived from the group's member
            // ids, so two devices pruning the same (day, task) group mint the
            // IDENTICAL rollup — after sync they merge as one record instead
            // of two pushed rollups double-counting the day forever. XOR of
            // member ids is order-independent; fragmentID stamps it into the
            // derived-id namespace (never collides with a random v4 id).
            var acc = uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            for member in sorted {
                withUnsafeBytes(of: member.id.uuid) { bytes in
                    withUnsafeMutableBytes(of: &acc) { a in
                        for i in 0..<16 { a[i] ^= bytes[i] }
                    }
                }
            }
            let rollupID = SessionMerge.fragmentID(parent: UUID(uuid: acc), index: 0)
            // Duration-weighted mean certainty (spec §Folds), the one fold rule
            // shared with the flush and mergeAdjacent — a long confident slice
            // is not dragged down by a brief uncertain one, nor oversold by it.
            let weightedCertainty = total > 0
                ? sorted.reduce(0.0) { $0 + $1.certainty * $1.end.timeIntervalSince($1.start) } / total
                : (sorted.map(\.certainty).max() ?? 1)
            create.append(Session(
                id: rollupID,
                task: sorted[0].task,
                start: sorted[0].start,
                end: sorted[0].start.addingTimeInterval(total),
                certainty: weightedCertainty,
                pushedToOP: true,
                comment: comment))
            deleteIDs += sorted.map(\.id)
        }
        create.sort { $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString }
        deleteIDs.sort { $0.uuidString < $1.uuidString }
        return Plan(create: create, deleteIDs: deleteIDs)
    }

    /// (c) Hard-cap prune — the STRONGLY DISCOURAGED escape hatch: delete the
    /// OLDEST raw slices, oldest-first, until the estimated footprint is back
    /// under `capBytes`. No creates (pure deletion, unlike (b)). Rollups
    /// (`SessionMerge.isDerivedID`) are NEVER candidates — deleting them
    /// barely helps (they're already ~1% of the size) and would destroy the
    /// exact history (b) exists to protect. A no-op when already under cap.
    package static func hardCapPlan(sessions: [Session], capBytes: Int) -> Plan {
        let encoder = JSONEncoder()
        func encodedSize(_ s: Session) -> Int { (try? encoder.encode(s).count) ?? 400 }
        let sized = sessions.map { ($0, encodedSize($0)) }
        var remaining = sized.reduce(0) { $0 + $1.1 }
        guard remaining > capBytes else { return Plan(create: [], deleteIDs: []) }
        let oldestFirst = sized
            .filter { !SessionMerge.isDerivedID($0.0.id) }
            .sorted { $0.0.start != $1.0.start ? $0.0.start < $1.0.start
                                              : $0.0.id.uuidString < $1.0.id.uuidString }
        var deleteIDs: [UUID] = []
        for (session, bytes) in oldestFirst {
            guard remaining > capBytes else { break }
            deleteIDs.append(session.id)
            remaining -= bytes
        }
        deleteIDs.sort { $0.uuidString < $1.uuidString }
        return Plan(create: [], deleteIDs: deleteIDs)
    }
}

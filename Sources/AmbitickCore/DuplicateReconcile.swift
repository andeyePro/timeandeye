import Foundation

/// A time entry as it exists in OpenProject (read back for reconciliation).
public struct OPTimeEntry: Equatable, Sendable, Identifiable {
    public var id: Int
    public var workPackageID: Int
    public var start: Date
    public var durationSeconds: TimeInterval
    public var comment: String?
    /// When OP recorded / last changed the entry — the key signal for telling an
    /// accidental duplicate from a deliberate second entry.
    public var createdAt: Date?
    public var updatedAt: Date?
    public var activity: String?
    /// Whether OP actually reported a per-entry start time. Some instances don't
    /// (the feature can be off), in which case `start` is just the day at
    /// midnight — the UI must not show a misleading "0:00", and grouping must not
    /// rely on the minute (it falls back to the journal count, below).
    public var hasStart: Bool
    public init(id: Int, workPackageID: Int, start: Date,
                durationSeconds: TimeInterval, comment: String? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil, activity: String? = nil,
                hasStart: Bool = true) {
        self.id = id
        self.workPackageID = workPackageID
        self.start = start
        self.durationSeconds = durationSeconds
        self.comment = comment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activity = activity
        self.hasStart = hasStart
    }
}

/// One proposed cleanup: keep the richest entry of a duplicate group, delete the
/// rest, and don't lose anything — the deleted entries' comments are folded into
/// the survivor, and any journal slice that pointed at a deleted entry is
/// re-pointed at the survivor. Applied ONE AT A TIME after the user confirms it.
public struct ReconcileAction: Equatable, Sendable, Identifiable {
    public var workPackageID: Int
    public var start: Date
    public var survivorID: Int
    public var deleteIDs: [Int]
    /// Every entry in the duplicate group (survivor + to-delete), so the UI can
    /// expand and show exactly what differs before you confirm.
    public var entries: [OPTimeEntry]
    /// The survivor's comment after folding in the deleted entries' comments, or
    /// nil when nothing needs to change on the survivor.
    public var mergedComment: String?
    /// Journal session ids that referenced a deleted entry and must be re-pointed
    /// to the survivor so future edits still PATCH the right OP entry.
    public var repointSessionIDs: [UUID]
    public var label: String
    public var id: Int { survivorID }

    public init(workPackageID: Int, start: Date, survivorID: Int, deleteIDs: [Int],
                entries: [OPTimeEntry], mergedComment: String?,
                repointSessionIDs: [UUID], label: String) {
        self.workPackageID = workPackageID
        self.start = start
        self.survivorID = survivorID
        self.deleteIDs = deleteIDs
        self.entries = entries
        self.mergedComment = mergedComment
        self.repointSessionIDs = repointSessionIDs
        self.label = label
    }
}

/// Pure, journal-driven duplicate-time-entry reconcile (the in-app maintenance
/// action; the MCP can see neither start times nor a delete verb). Policy
/// (Martin): never two records for one point in time; keep the RICHEST record
/// (most likely the real one), fold the deleted records' comments into the
/// survivor so nothing is irrecoverable, re-point the journal at the survivor,
/// and — the safety rail — NEVER touch a group that has no matching journal
/// slice (it could be a hand-entered OP entry).
public enum DuplicateReconcile {
    private static func minuteKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 60).rounded(.down)) }
    private static func durMin(_ s: TimeInterval) -> Int { Int((s / 60).rounded()) }

    public static func plan(entries: [OPTimeEntry], sessions: [Session]) -> [ReconcileAction] {
        // Key on task + start-minute + duration (never duration alone, never
        // start alone): two records at the same point in time for the same task
        // with the same length.
        var groups: [String: [OPTimeEntry]] = [:]
        for e in entries {
            groups["\(e.workPackageID)@\(minuteKey(e.start))#\(durMin(e.durationSeconds))",
                   default: []].append(e)
        }
        var actions: [ReconcileAction] = []
        for group in groups.values where group.count > 1 {
            let wp = group[0].workPackageID
            let mk = minuteKey(group[0].start)
            let dm = durMin(group[0].durationSeconds)
            let ids = Set(group.map(\.id))
            // How many of these are REAL, per the journal (the source of truth):
            // slices linked to one of the entries, or matching task+minute+
            // duration. The journal decides the count, so this stays safe even
            // when OP doesn't report per-entry start times (everything would
            // otherwise collapse to a day). realCount 0 → no journal evidence →
            // never touch (could be hand-entered in OP).
            let realCount = sessions.filter { s in
                (s.opTimeEntryID.map { ids.contains($0) } ?? false)
                    || (s.task == .op(wp) && minuteKey(s.start) == mk
                        && durMin(s.end.timeIntervalSince(s.start)) == dm)
            }.count
            guard realCount >= 1, group.count > realCount else { continue }
            // Keep the `realCount` richest (most comment, then longest, then
            // lowest id); the excess are the spurious copies to delete.
            let ranked = group.sorted { a, b in
                let (ca, cb) = (a.comment?.count ?? 0, b.comment?.count ?? 0)
                if ca != cb { return ca > cb }
                if a.durationSeconds != b.durationSeconds { return a.durationSeconds > b.durationSeconds }
                return a.id < b.id
            }
            let survivor = ranked[0]
            let deletes = Array(ranked.dropFirst(realCount))
            guard !deletes.isEmpty else { continue }
            // Fold every distinct non-empty comment into the survivor.
            var seen = Set<String>()
            var merged: [String] = []
            for c in ([survivor.comment] + deletes.map(\.comment)) {
                let t = c?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty, seen.insert(t).inserted { merged.append(t) }
            }
            let mergedText = merged.joined(separator: "; ")
            let mergedComment = (mergedText.isEmpty || mergedText == (survivor.comment ?? "")) ? nil : mergedText
            let deleteIDs = deletes.map(\.id)
            let repoint = sessions
                .filter { s in s.opTimeEntryID.map { deleteIDs.contains($0) } ?? false }
                .map(\.id)
            actions.append(ReconcileAction(
                workPackageID: wp, start: survivor.start, survivorID: survivor.id,
                deleteIDs: deleteIDs,
                entries: group.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) },
                mergedComment: mergedComment, repointSessionIDs: repoint,
                label: "WP #\(wp): keep entry #\(survivor.id), delete \(deleteIDs.count) duplicate"
                    + (deleteIDs.count == 1 ? "" : "s")))
        }
        return actions.sorted { ($0.entries.first?.createdAt ?? $0.start) < ($1.entries.first?.createdAt ?? $1.start) }
    }
}

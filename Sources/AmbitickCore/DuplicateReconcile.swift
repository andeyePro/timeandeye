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
    public init(id: Int, workPackageID: Int, start: Date,
                durationSeconds: TimeInterval, comment: String? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil, activity: String? = nil) {
        self.id = id
        self.workPackageID = workPackageID
        self.start = start
        self.durationSeconds = durationSeconds
        self.comment = comment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activity = activity
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
    private static func minuteKey(_ d: Date) -> Int {
        Int((d.timeIntervalSince1970 / 60).rounded(.down))
    }

    public static func plan(entries: [OPTimeEntry], sessions: [Session]) -> [ReconcileAction] {
        var groups: [String: [OPTimeEntry]] = [:]
        for e in entries {
            groups["\(e.workPackageID)@\(minuteKey(e.start))", default: []].append(e)
        }
        var actions: [ReconcileAction] = []
        for group in groups.values where group.count > 1 {
            let wp = group[0].workPackageID
            let mk = minuteKey(group[0].start)
            let ids = Set(group.map(\.id))
            // Safety rail: only reconcile a group that is genuinely app-tracked
            // time — a journal slice at the same task+minute, or one already
            // linked to an entry in the group. Otherwise leave it alone (could be
            // hand-entered in OP).
            let matched = sessions.contains { s in
                (s.task == .op(wp) && minuteKey(s.start) == mk)
                    || (s.opTimeEntryID.map { ids.contains($0) } ?? false)
            }
            guard matched else { continue }
            // Survivor = richest: most comment, then longest, then lowest id.
            let survivor = group.max { a, b in
                let (ca, cb) = (a.comment?.count ?? 0, b.comment?.count ?? 0)
                if ca != cb { return ca < cb }
                if a.durationSeconds != b.durationSeconds { return a.durationSeconds < b.durationSeconds }
                return a.id > b.id
            }!
            let deletes = group.filter { $0.id != survivor.id }
            // Fold every distinct non-empty comment into the survivor.
            var seen = Set<String>()
            var merged: [String] = []
            for c in ([survivor.comment] + deletes.map(\.comment)) {
                let t = c?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty, seen.insert(t).inserted { merged.append(t) }
            }
            let mergedText = merged.joined(separator: "; ")
            let mergedComment = mergedText == (survivor.comment ?? "") ? nil
                : (mergedText.isEmpty ? nil : mergedText)
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
        return actions.sorted { $0.start < $1.start }
    }
}

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
/// Backend-neutral since the RemoteTimeEntry generalisation: ids are Strings.
public struct ReconcileAction: Equatable, Sendable, Identifiable {
    public var taskID: String
    public var start: Date
    public var survivorID: RemoteEntryID
    public var deleteIDs: [RemoteEntryID]
    /// Every entry in the duplicate group (survivor + to-delete), so the UI can
    /// expand and show exactly what differs before you confirm.
    public var entries: [RemoteTimeEntry]
    /// The survivor's comment after folding in the deleted entries' comments, or
    /// nil when nothing needs to change on the survivor.
    public var mergedComment: String?
    /// Journal session ids that referenced a deleted entry and must be re-pointed
    /// to the survivor so future edits still PATCH the right backend entry.
    public var repointSessionIDs: [UUID]
    public var label: String
    public var id: String { survivorID }

    public init(taskID: String, start: Date, survivorID: RemoteEntryID,
                deleteIDs: [RemoteEntryID], entries: [RemoteTimeEntry],
                mergedComment: String?, repointSessionIDs: [UUID], label: String) {
        self.taskID = taskID
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

    public static func plan(entries: [RemoteTimeEntry], sessions: [Session]) -> [ReconcileAction] {
        // Key on task + start-minute + duration (never duration alone, never
        // start alone): two records at the same point in time for the same task
        // with the same length.
        var groups: [String: [RemoteTimeEntry]] = [:]
        for e in entries {
            groups["\(e.taskID)@\(minuteKey(e.start))#\(durMin(e.durationSeconds))",
                   default: []].append(e)
        }
        var actions: [ReconcileAction] = []
        for group in groups.values where group.count > 1 {
            let taskID = group[0].taskID
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
                    || (s.task.backendTaskID == taskID && minuteKey(s.start) == mk
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
            let deleteIDSet = Set(deleteIDs)
            let repoint = sessions
                .filter { s in s.opTimeEntryID.map { deleteIDSet.contains($0) } ?? false }
                .map(\.id)
            actions.append(ReconcileAction(
                taskID: taskID, start: survivor.start, survivorID: survivor.id,
                deleteIDs: deleteIDs,
                entries: group.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) },
                mergedComment: mergedComment, repointSessionIDs: repoint,
                label: "Task \(taskID): keep entry \(survivor.id), delete \(deleteIDs.count) duplicate"
                    + (deleteIDs.count == 1 ? "" : "s")))
        }
        return actions.sorted { ($0.entries.first?.createdAt ?? $0.start) < ($1.entries.first?.createdAt ?? $1.start) }
    }
}

/// Everything needed to REVERSE an applied reconcile — the "reconcile
/// journal" the undo audit called for, held in the undo closure (session-
/// bounded, like every other ⌘Z step). The duplicates are DELETED at the
/// backend, so undo can't restore the old pointers: the ids are dead and a
/// later timeline edit would PATCH a 404. Instead it re-CREATES the entries
/// verbatim from this snapshot and re-points each slice at its entry's
/// FRESH backend-assigned id. Must be built BEFORE the apply mutates
/// anything (the sessions still hold their old pointers).
public struct ReconcileUndoPlan: Equatable, Sendable {
    /// The deleted entries, whole (comment, start, length, activity) — undo
    /// re-creates each at the backend.
    public var recreate: [RemoteTimeEntry]
    public var survivorID: RemoteEntryID
    /// Rewrite the survivor's comment back to this pre-merge text. nil when
    /// the apply never touched it; "" actively clears a survivor that had no
    /// comment before the fold.
    public var restoreSurvivorComment: String?
    /// Session id → the deleted entry id it pointed at before the re-point,
    /// so each slice follows its OWN entry's re-created id back out.
    public var priorEntryIDBySession: [UUID: RemoteEntryID]

    public init(recreate: [RemoteTimeEntry], survivorID: RemoteEntryID,
                restoreSurvivorComment: String?,
                priorEntryIDBySession: [UUID: RemoteEntryID]) {
        self.recreate = recreate
        self.survivorID = survivorID
        self.restoreSurvivorComment = restoreSurvivorComment
        self.priorEntryIDBySession = priorEntryIDBySession
    }
}

public extension DuplicateReconcile {
    /// Snapshot `action`'s reversal. `sessions` are the CURRENT journal rows
    /// for `action.repointSessionIDs`, fetched before the apply re-points
    /// them — their `opTimeEntryID` still names the doomed entry.
    static func undoPlan(for action: ReconcileAction,
                         sessions: [Session]) -> ReconcileUndoPlan {
        let deleteSet = Set(action.deleteIDs)
        let survivorComment = action.entries
            .first { $0.id == action.survivorID }?.comment
        return ReconcileUndoPlan(
            recreate: action.entries.filter { deleteSet.contains($0.id) },
            survivorID: action.survivorID,
            // The apply rewrites the comment only when mergedComment is set;
            // undo mirrors that exactly (nil = hands off).
            restoreSurvivorComment: action.mergedComment == nil
                ? nil : (survivorComment ?? ""),
            priorEntryIDBySession: Dictionary(uniqueKeysWithValues:
                sessions.compactMap { s in
                    guard let old = s.opTimeEntryID, deleteSet.contains(old)
                    else { return nil }
                    return (s.id, old)
                }))
    }
}

import Foundation

/// Pushes journalled sessions to the connected backend once they clear the
/// user's certainty threshold. The journal stays the source of truth; a failed
/// push leaves the session queued. Backend-agnostic: OP quirks (startTime 422
/// fallback etc.) live in the backend conformer, and in standalone mode no
/// SyncEngine exists at all (see TaskBackend).
public final class SyncEngine {
    private let journal: any JournalStore
    private let backend: any TaskBackend
    public var onDebug: (String) -> Void = { _ in }

    public init(journal: any JournalStore, backend: any TaskBackend) {
        self.journal = journal
        self.backend = backend
    }

    /// Returns the number of sessions pushed. Throws on the first failure,
    /// leaving that session and later ones unmarked for retry.
    @discardableResult
    public func pushEligible(threshold: Double, defaultActivityID: Int? = nil,
                             activityOverrides: [TaskRef: Int] = [:],
                             includeComments: Bool) async throws -> Int {
        var pushed = 0
        for session in try journal.sessions(needingPushAtOrAbove: threshold) {
            // Ownership guard: an .op session must never push to Xero (nor
            // vice versa). Un-owned sessions stay queued for their backend —
            // skipped silently, never marked pushed.
            guard backend.owns(session.task),
                  let taskID = session.task.backendTaskID else { continue }
            let duration = session.end.timeIntervalSince(session.start)
            if duration < 60 {
                // Too short for a backend entry (OP would round it to PT0H0M);
                // mark it handled so it does not clog the queue forever.
                try journal.markPushed(session.id, opTimeEntryID: nil)
                continue
            }
            let activity = activityOverrides[session.task] ?? defaultActivityID
            let comment = includeComments ? session.comment : nil
            let entryID = try await backend.createTimeEntry(
                taskID: taskID, start: session.start, duration: duration,
                activityID: activity, comment: comment)
            // The create succeeded; the backend now holds the entry. If marking
            // the journal fails (save() can throw on the SQLite store), the
            // session would stay unpushed and the next sync would re-POST it =
            // duplicate. Roll the backend back to match the journal: best-effort
            // delete the just-created entry, then rethrow so the session
            // retries clean.
            do {
                try journal.markPushed(session.id, opTimeEntryID: entryID)
            } catch {
                if let entryID {
                    do { try await backend.deleteTimeEntry(id: entryID) }
                    catch { onDebug("orphan cleanup failed for entry \(entryID): \(error)") }
                }
                throw error
            }
            pushed += 1
        }
        return pushed
    }
}

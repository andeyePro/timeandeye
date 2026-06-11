import Foundation

/// Pushes journalled sessions to OP once they clear the user's certainty
/// threshold. The journal stays the source of truth; a failed push leaves
/// the session queued.
public final class SyncEngine {
    private let journal: any JournalStore
    private let client: OPClient

    public init(journal: any JournalStore, client: OPClient) {
        self.journal = journal
        self.client = client
    }

    /// Returns the number of sessions pushed. Throws on the first failure,
    /// leaving that session and later ones unmarked for retry.
    @discardableResult
    public func pushEligible(threshold: Double, defaultActivityID: Int,
                             activityOverrides: [TaskRef: Int] = [:],
                             includeComments: Bool) async throws -> Int {
        var pushed = 0
        for session in try journal.sessions(needingPushAtOrAbove: threshold) {
            guard case .op(let wpID) = session.task else { continue }
            let duration = session.end.timeIntervalSince(session.start)
            if duration < 60 {
                // Too short for an OP entry (would round to PT0H0M); mark it
                // handled so it does not clog the queue forever.
                try journal.markPushed(session.id)
                continue
            }
            try await client.createTimeEntry(
                workPackageID: wpID,
                start: session.start,
                duration: duration,
                activityID: activityOverrides[session.task] ?? defaultActivityID,
                comment: includeComments ? session.comment : nil)
            try journal.markPushed(session.id)
            pushed += 1
        }
        return pushed
    }
}

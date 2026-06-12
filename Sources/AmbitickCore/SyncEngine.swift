import Foundation

/// Pushes journalled sessions to OP once they clear the user's certainty
/// threshold. The journal stays the source of truth; a failed push leaves
/// the session queued.
public final class SyncEngine {
    private let journal: any JournalStore
    private let client: OPClient
    public var onDebug: (String) -> Void = { _ in }
    public private(set) var startTimesSupported = true

    public init(journal: any JournalStore, client: OPClient) {
        self.journal = journal
        self.client = client
    }

    /// OP's TimeEntry.startTime is an ISO 8601 date-time in UTC (verified
    /// against the API schema; "HH:mm" gets a 422). OP converts to the
    /// user's timezone for display.
    private static let timeFormatter = ISO8601DateFormatter()

    /// Returns the number of sessions pushed. Throws on the first failure,
    /// leaving that session and later ones unmarked for retry.
    @discardableResult
    public func pushEligible(threshold: Double, defaultActivityID: Int? = nil,
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
            let activity = activityOverrides[session.task] ?? defaultActivityID
            let comment = includeComments ? session.comment : nil
            do {
                try await client.createTimeEntry(
                    workPackageID: wpID, start: session.start, duration: duration,
                    activityID: activity, comment: comment,
                    startTime: startTimesSupported
                        ? Self.timeFormatter.string(from: session.start) : nil)
            } catch OPClientError.httpStatus(422, let body) where startTimesSupported {
                // Diagnose, don't just survive: WHY did OP refuse the timed
                // entry? (Overlap validation, feature off, ...)
                onDebug("422 with startTime, retrying without. body: \(body.prefix(300))")
                startTimesSupported = false
                try await client.createTimeEntry(
                    workPackageID: wpID, start: session.start, duration: duration,
                    activityID: activity, comment: comment, startTime: nil)
            }
            try journal.markPushed(session.id)
            pushed += 1
        }
        return pushed
    }
}

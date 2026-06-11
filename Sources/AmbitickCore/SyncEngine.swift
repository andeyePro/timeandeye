import Foundation

/// Pushes journalled sessions to OP once they clear the user's certainty
/// threshold. The journal stays the source of truth; a failed push leaves
/// the session queued.
public final class SyncEngine {
    private let journal: any JournalStore
    private let client: OPClient
    private var startTimesSupported = true

    public init(journal: any JournalStore, client: OPClient) {
        self.journal = journal
        self.client = client
    }

    /// "HH:mm" in the Mac's local timezone — what OP's calendar views expect.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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
            } catch OPClientError.httpStatus(422, _) where startTimesSupported {
                // Instance has start/end-time tracking disabled: retry plain
                // and stop sending start times this run.
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

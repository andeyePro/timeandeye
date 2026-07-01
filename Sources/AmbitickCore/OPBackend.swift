import Foundation

/// OpenProject behind the TaskBackend seam. Owns the OP-specific quirks so
/// nothing above the seam needs to know them: the startTime-422 fallback
/// (instances can have start times disabled), page/PWA-title recognition, and
/// the work-package URL scheme.
public final class OPBackend: TaskBackend {
    private let client: OPClient
    private let baseURL: URL
    public var onDebug: (String) -> Void = { _ in }

    /// OP's TimeEntry.startTime is an ISO 8601 date-time in UTC (verified
    /// against the API schema; "HH:mm" gets a 422). OP converts to the
    /// user's timezone for display.
    private static let timeFormatter = ISO8601DateFormatter()

    /// Flips false on the first startTime 422 so one refusal stops further
    /// attempts for the process lifetime (mirrors the old SyncEngine flag).
    public private(set) var startTimesSupported = true

    public init(baseURL: URL, apiKey: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.client = OPClient(baseURL: baseURL, apiKey: apiKey, transport: transport)
    }

    public var displayName: String { "OpenProject" }
    public var supportsActivities: Bool { true }
    public var pageRecognizer: BackendPageRecognizer {
        OPPageRecognizer(instanceHost: baseURL.host ?? "")
    }

    public func fetchTasks() async throws -> [WorkTask] {
        try await client.fetchTasks()
    }

    public func fetchMe() async throws -> String {
        try await client.fetchMe()
    }

    public func fetchActivities() async throws -> [TimeActivity] {
        try await client.fetchActivities()
    }

    public func taskURL(id: Int) -> URL? {
        baseURL.appendingPathComponent("work_packages/\(id)")
    }

    public func createTimeEntry(taskID: Int, start: Date, duration: TimeInterval,
                                activityID: Int?, comment: String?) async throws -> RemoteEntryID? {
        do {
            return try await client.createTimeEntry(
                workPackageID: taskID, start: start, duration: duration,
                activityID: activityID, comment: comment,
                startTime: startTimesSupported
                    ? Self.timeFormatter.string(from: start) : nil)
        } catch OPClientError.httpStatus(422, let body) where startTimesSupported {
            // Diagnose, don't just survive: WHY did OP refuse the timed
            // entry? (Overlap validation, feature off, ...)
            onDebug("422 with startTime, retrying without. body: \(body.prefix(300))")
            startTimesSupported = false
            return try await client.createTimeEntry(
                workPackageID: taskID, start: start, duration: duration,
                activityID: activityID, comment: comment, startTime: nil)
        }
    }

    public func updateTimeEntry(id: RemoteEntryID, taskID: Int, start: Date,
                                duration: TimeInterval, activityID: Int?,
                                comment: String?) async throws {
        try await client.updateTimeEntry(
            id: id, workPackageID: taskID, start: start, duration: duration,
            activityID: activityID, comment: comment,
            startTime: startTimesSupported ? Self.timeFormatter.string(from: start) : nil)
    }

    public func updateEntryComment(id: RemoteEntryID, comment: String) async throws {
        try await client.updateTimeEntryComment(id: id, comment: comment)
    }

    public func deleteTimeEntry(id: RemoteEntryID) async throws {
        try await client.deleteTimeEntry(id: id)
    }

    public func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry] {
        try await client.listTimeEntries(from: from, to: to)
    }

    public func addTaskComment(taskID: Int, text: String) async throws {
        try await client.addWorkPackageComment(id: taskID, text: text)
    }
}

/// OP task pages: `/work_packages/<id>` URLs on the instance host, "#<id>"
/// in a PWA window title, and `/projects/` pages as project-scoped.
public struct OPPageRecognizer: BackendPageRecognizer {
    public let instanceHost: String

    public init(instanceHost: String) {
        self.instanceHost = instanceHost
    }

    public func taskID(inURL urlString: String) -> Int? {
        OPURLParser.taskID(in: urlString, instanceHost: instanceHost)
    }

    public func taskID(inTitle title: String) -> Int? {
        OPURLParser.taskID(inTitle: title)
    }

    public func isProjectPage(_ url: URL) -> Bool {
        url.host == instanceHost && url.path.contains("/projects/")
    }
}

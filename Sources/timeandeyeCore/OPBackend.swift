import Foundation

/// OpenProject behind the TaskBackend seam. Owns the OP-specific quirks so
/// nothing above the seam needs to know them: the startTime-422 fallback
/// (instances can have start times disabled), page/PWA-title recognition, and
/// the work-package URL scheme.
public final class OPBackend: TaskBackend {
    /// The built-in OpenProject connection's STABLE registry/ledger id (see
    /// RegisteredBackend.id). One OP instance per app in v1, so a constant is
    /// exactly stable; per-connection minted ids arrive with the deferred
    /// duplicate-instance (TaskRef identity) work. The single-slot →
    /// posting-ledger migration maps every legacy `pushedToOP` row to this id,
    /// so it must never change.
    public static let stableID = "openproject"

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
    public var supportsTaskComments: Bool { true }

    public func owns(_ ref: TaskRef) -> Bool {
        if case .op = ref { return true }
        return false
    }
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

    public func taskURL(id: String) -> URL? {
        Int(id).map { baseURL.appendingPathComponent("work_packages/\($0)") }
    }

    /// The global cost report pre-filtered to this work package — the same
    /// link OP's own "spent time" field builds (wp-spent-time-display-field
    /// in opf/openproject, verified 2026-07-09; the query grammar is the
    /// reporting module's CostQuery filter, unchanged since at least v12).
    /// OP has no per-time-entry page, so this is where "check the entries"
    /// lands.
    public func taskTimeEntriesURL(id: String) -> URL? {
        guard let n = Int(id),
              var comps = URLComponents(url: baseURL.appendingPathComponent("cost_reports"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "fields[]", value: "WorkPackageId"),
            URLQueryItem(name: "operators[WorkPackageId]", value: "="),
            URLQueryItem(name: "values[WorkPackageId]", value: String(n)),
            URLQueryItem(name: "set_filter", value: "1"),
        ]
        return comps.url
    }

    /// OP entry/task ids are ints; the seam speaks String (Xero uses GUIDs).
    /// A non-numeric id here can only mean cross-backend corruption — surface
    /// it, never silently no-op.
    private func opID(_ id: RemoteEntryID) throws -> Int {
        guard let n = Int(id) else {
            throw OPClientError.malformedResponse("non-numeric OP entry id '\(id)'")
        }
        return n
    }

    private func opTaskID(_ id: String) throws -> Int {
        guard let n = Int(id) else {
            throw OPClientError.malformedResponse("non-numeric OP task id '\(id)'")
        }
        return n
    }

    public func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                                activityID: Int?, comment: String?) async throws -> RemoteEntryID? {
        let wpID = try opTaskID(taskID)
        do {
            return try await client.createTimeEntry(
                workPackageID: wpID, start: start, duration: duration,
                activityID: activityID, comment: comment,
                startTime: startTimesSupported
                    ? Self.timeFormatter.string(from: start) : nil).map(String.init)
        } catch OPClientError.httpStatus(422, let body) where startTimesSupported {
            // Diagnose, don't just survive: WHY did OP refuse the timed
            // entry? (Overlap validation, feature off, ...)
            onDebug("422 with startTime, retrying without. body: \(body.prefix(300))")
            startTimesSupported = false
            return try await client.createTimeEntry(
                workPackageID: wpID, start: start, duration: duration,
                activityID: activityID, comment: comment, startTime: nil).map(String.init)
        }
    }

    public func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                                duration: TimeInterval, activityID: Int?,
                                comment: String?) async throws {
        try await client.updateTimeEntry(
            id: opID(id), workPackageID: try opTaskID(taskID), start: start,
            duration: duration, activityID: activityID, comment: comment,
            startTime: startTimesSupported ? Self.timeFormatter.string(from: start) : nil)
    }

    public func updateEntryComment(id: RemoteEntryID, comment: String) async throws {
        try await client.updateTimeEntryComment(id: opID(id), comment: comment)
    }

    public func deleteTimeEntry(id: RemoteEntryID) async throws {
        try await client.deleteTimeEntry(id: opID(id))
    }

    public func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry] {
        try await client.listTimeEntries(from: from, to: to).map { e in
            RemoteTimeEntry(id: String(e.id), taskID: String(e.workPackageID),
                            start: e.start, durationSeconds: e.durationSeconds,
                            comment: e.comment, createdAt: e.createdAt,
                            updatedAt: e.updatedAt, activity: e.activity,
                            hasStart: e.hasStart)
        }
    }

    public func addTaskComment(taskID: String, text: String) async throws {
        try await client.addWorkPackageComment(id: try opTaskID(taskID), text: text)
    }
}

/// OP task pages: `/work_packages/<id>` URLs on the instance host, "#<id>"
/// in a PWA window title, and `/projects/` pages as project-scoped.
public struct OPPageRecognizer: BackendPageRecognizer {
    public let instanceHost: String

    public init(instanceHost: String) {
        self.instanceHost = instanceHost
    }

    public func taskRef(inURL urlString: String) -> TaskRef? {
        OPURLParser.taskID(in: urlString, instanceHost: instanceHost).map(TaskRef.op)
    }

    public func taskRef(inTitle title: String) -> TaskRef? {
        OPURLParser.taskID(inTitle: title).map(TaskRef.op)
    }

    public func isProjectPage(_ url: URL) -> Bool {
        url.host == instanceHost && url.path.contains("/projects/")
    }

    /// The slug straight after /projects/ ("/projects/alpha-beta/work_packages"
    /// → "alpha-beta") — OP's project identifier, usually the kebab-cased
    /// title.
    public func projectHint(in url: URL) -> String? {
        guard url.host == instanceHost else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "projects"), i + 1 < parts.count else { return nil }
        let slug = parts[i + 1]
        return slug.isEmpty ? nil : slug
    }
}

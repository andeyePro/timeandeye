import Foundation

/// A time entry's id in the connected backend. String because backends
/// disagree (OP: ints, Xero: GUIDs); the OP conformer converts at its edge.
public typealias RemoteEntryID = String

/// A backend "activity" type attached to time entries (OP: Development,
/// Management, ...). Backends without the concept return [].
public typealias TimeActivity = OPTimeActivity

/// A time entry as it exists in the backend, read back for reconciliation.
public typealias RemoteTimeEntry = OPTimeEntry

/// How the backend's task pages show up in captured browser URLs / window
/// titles — the attribution engine's "you are looking at task N right now"
/// hook. Standalone mode recognises nothing.
public protocol BackendPageRecognizer: Sendable {
    /// The task when `urlString` is one of the backend's task pages.
    func taskRef(inURL urlString: String) -> TaskRef?
    /// Fallback for surfaces with no readable URL (backend opened as a PWA):
    /// the task embedded in a window title / app name, if recognisable.
    func taskRef(inTitle title: String) -> TaskRef?
    /// True when the URL is a project-scoped page on the backend with no task
    /// id — the ranker then trusts its priors harder ("the most appropriate
    /// task in that project").
    func isProjectPage(_ url: URL) -> Bool
}

/// The seam between Ambitick and whatever holds the canonical task list +
/// timesheet: OpenProject today, Xero next. One in-process conformer per
/// backend; the journal stays the local source of truth either way.
/// Standalone mode is the ABSENCE of a backend (nil, never a silent no-op
/// sink): with no backend there is no SyncEngine, so nothing can be marked
/// pushed without having gone anywhere.
public protocol TaskBackend: AnyObject {
    /// Shown in Settings / errors ("OpenProject", "Xero").
    var displayName: String { get }
    /// Task-page recognition for the attribution engine.
    var pageRecognizer: BackendPageRecognizer { get }
    /// Whether the backend has per-entry activity types (drives the Settings
    /// pickers; false hides them).
    var supportsActivities: Bool { get }
    /// Whether this ref belongs to this backend — an `.op` session must never
    /// push to Xero, nor vice versa. Un-owned eligible sessions are skipped
    /// silently (they push when their backend reconnects), never marked.
    func owns(_ ref: TaskRef) -> Bool

    // MARK: Task list
    func fetchTasks() async throws -> [WorkTask]
    /// Who the credentials authenticate as — surfaced so time can never be
    /// silently logged to the wrong account.
    func fetchMe() async throws -> String
    func fetchActivities() async throws -> [TimeActivity]
    /// The task's web page, for "Open in <backend>".
    func taskURL(id: String) -> URL?

    // MARK: Time entries
    /// Creates an entry and returns its id (nil when the backend replies
    /// without one). The backend owns its own encoding quirks — e.g. OP's
    /// startTime 422 fallback lives in the OP conformer, not the SyncEngine.
    /// Task ids are String (the `TaskRef.backendTaskID` form): OP converts to
    /// Int at its edge, GUID backends use them verbatim.
    func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                         activityID: Int?, comment: String?) async throws -> RemoteEntryID?
    func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                         duration: TimeInterval, activityID: Int?,
                         comment: String?) async throws
    func updateEntryComment(id: RemoteEntryID, comment: String) async throws
    func deleteTimeEntry(id: RemoteEntryID) async throws
    /// The current user's entries spent in [from, to] — duplicate-reconcile's
    /// input. Backends that cannot list return [].
    func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry]

    // MARK: Comments
    /// Post a note to the task itself (OP: the work package's activity feed),
    /// where it is findable — not buried on a single time entry.
    func addTaskComment(taskID: String, text: String) async throws
}

/// A recognizer that never matches — standalone, and any backend whose pages
/// carry no task identity.
public struct NoPageRecognizer: BackendPageRecognizer {
    public init() {}
    public func taskRef(inURL urlString: String) -> TaskRef? { nil }
    public func taskRef(inTitle title: String) -> TaskRef? { nil }
    public func isProjectPage(_ url: URL) -> Bool { false }
}

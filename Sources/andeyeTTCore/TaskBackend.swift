import Foundation

/// A time entry's id in the connected backend. String because backends
/// disagree (OP: ints, Xero: GUIDs); the OP conformer converts at its edge.
public typealias RemoteEntryID = String

/// A backend "activity" type attached to time entries (OP: Development,
/// Management, ...). Backends without the concept return [].
public typealias TimeActivity = OPTimeActivity

/// A time entry as it exists in the backend, read back for reconciliation.
/// String ids throughout (`TaskRef.backendTaskID` form): OP converts its
/// ints at the edge, GUID backends use theirs verbatim.
public struct RemoteTimeEntry: Equatable, Sendable, Identifiable {
    public var id: RemoteEntryID
    public var taskID: String
    public var start: Date
    public var durationSeconds: TimeInterval
    public var comment: String?
    /// When the backend recorded / last changed the entry — the key signal
    /// for telling an accidental duplicate from a deliberate second entry.
    public var createdAt: Date?
    public var updatedAt: Date?
    public var activity: String?
    /// Whether the backend reported a real per-entry start time (OP can have
    /// the feature off; Xero may be day-granular) — grouping must not trust
    /// the minute when false.
    public var hasStart: Bool

    public init(id: RemoteEntryID, taskID: String, start: Date,
                durationSeconds: TimeInterval, comment: String? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil,
                activity: String? = nil, hasStart: Bool = true) {
        self.id = id
        self.taskID = taskID
        self.start = start
        self.durationSeconds = durationSeconds
        self.comment = comment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activity = activity
        self.hasStart = hasStart
    }
}

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
    /// A project identifier hinted by the page URL (OP: the slug after
    /// /projects/), for scoping the project-page ranking boost to THAT
    /// project's tasks. nil = page identifies no particular project.
    func projectHint(in url: URL) -> String?
}

public extension BackendPageRecognizer {
    func projectHint(in url: URL) -> String? { nil }
}

/// The seam between andeye and whatever holds the canonical task list +
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
    /// Whether notes can be posted to the task itself (OP: activity feed —
    /// yes; Xero Projects: no such endpoint). False = the controller skips
    /// comment-to-task rather than erroring per note.
    var supportsTaskComments: Bool { get }
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

    // MARK: Invoice locks (the invoice-lock layer — Martin's proposal, 2026-07-08)
    /// Which of `ids` are covered by a SENT invoice at the backend, and under
    /// which reference. The answer is authoritative for the ids ASKED: an id
    /// absent from the result is not invoiced. Xero's Projects API exposes
    /// entry status (INVOICED/LOCKED) but not the invoice number, so its ref
    /// is the constant "Xero"; a backend that can name the invoice returns
    /// the number. Backends without an invoicing concept (OP) keep the
    /// default: [:], nothing ever locks.
    func invoiceLocks(for ids: [RemoteEntryID]) async throws -> [RemoteEntryID: String]
}

public extension TaskBackend {
    func invoiceLocks(for ids: [RemoteEntryID]) async throws -> [RemoteEntryID: String] { [:] }
}

/// Thrown by a connector when a posting can NEVER succeed — the task was
/// deleted at the backend, the entry is frozen by invoicing, the connector
/// has no mapping for this task — as opposed to transient failures (network,
/// 5xx, rate limits), which stay retryable. The SyncEngine closes the row
/// `.skipped` with the reason and MOVES ON, so one permanently-rejected
/// session never dams the queue behind it. Classification is the
/// connector's job: only it can tell a 404-task from a 503.
public struct PermanentPostError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Thrown by a connector's update/delete when an AMENDMENT can't proceed as
/// asked — the engine reacts per case rather than retrying blindly.
public enum AmendmentError: Error, Equatable {
    /// The entry is locked/invoiced at the backend: the journal-side change
    /// cannot propagate. The engine parks the row `.diverged` (surfaced).
    case frozen(String)
    /// The backend cannot move this entry in place (Xero: across projects):
    /// the engine deletes and recreates instead.
    case mustRecreate
}

/// A recognizer that never matches — standalone, and any backend whose pages
/// carry no task identity.
public struct NoPageRecognizer: BackendPageRecognizer {
    public init() {}
    public func taskRef(inURL urlString: String) -> TaskRef? { nil }
    public func taskRef(inTitle title: String) -> TaskRef? { nil }
    public func isProjectPage(_ url: URL) -> Bool { false }
}

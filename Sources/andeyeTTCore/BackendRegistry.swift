import Foundation

/// The role a registered backend plays in sync routing. Deliberately a
/// raw-string struct, not an enum: connectors ship in OTHER packages
/// (andeyePro), so the set of classes must be extensible without touching
/// this file. Two classes exist today:
///
/// - `.pm` (project management): receives ALL confirmed time for the tasks it
///   owns (`TaskBackend.owns`) — the complete PM record, billable or not.
/// - `.finance` (invoicing): receives ONLY sessions whose effective billable
///   resolution is billable. Finance eligibility deliberately BYPASSES
///   `owns()` — a session on a pm-owned task still reaches a finance backend
///   when billable (ownership routes pm posting, billability routes finance
///   posting). Non-billable and personal (`.local`) time is invisible to it.
///
/// A class the sync layer does not recognise receives nothing (the safe
/// direction) until a routing rule for it exists.
public struct BackendClass: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Project management (OpenProject today): all owned confirmed time.
    public static let pm = BackendClass(rawValue: "pm")
    /// Finance/invoicing (Xero via andeyePro): billable time only.
    public static let finance = BackendClass(rawValue: "finance")
}

/// One registry entry: a connector plus the identity and class that route it.
public struct RegisteredBackend {
    /// STABLE identity for this connection — it keys the posting ledger, so it
    /// must never change across launches (a changed id re-posts history).
    /// Connector-agnostic: the registrant picks it (`OPBackend.stableID` for
    /// the built-in OpenProject connection; a connect-time-minted, persisted
    /// id for anything else). Duplicate-instance ids (two orgs of one kind)
    /// are deferred with the TaskRef-identity work.
    public let id: String
    public let backendClass: BackendClass
    public let backend: any TaskBackend

    public init(id: String, class backendClass: BackendClass, backend: any TaskBackend) {
        self.id = id
        self.backendClass = backendClass
        self.backend = backend
    }
}

/// Holds the N `(TaskBackend, class)` entries the sync fan-out iterates.
/// Connector-agnostic: nothing here names a product. The community app
/// registers exactly one pm backend (OpenProject) and behaves exactly as the
/// old single-slot code did; andeyePro registers its paid connectors through
/// `AppController.register(backend:id:class:)` — THE seam between the repos.
public final class BackendRegistry {
    /// Registration order is significant: the first pm entry is the "primary"
    /// whose single-backend conveniences (task list, entry PATCH/DELETE on
    /// timeline edits) the app surfaces.
    public private(set) var entries: [RegisteredBackend] = []

    public init() {}

    /// Register (or replace — same id) a backend. Idempotent per id.
    public func register(_ backend: any TaskBackend, id: String,
                         class backendClass: BackendClass) {
        entries.removeAll { $0.id == id }
        entries.append(RegisteredBackend(id: id, class: backendClass, backend: backend))
    }

    public func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    public func entry(id: String) -> RegisteredBackend? {
        entries.first { $0.id == id }
    }

    public func entries(class backendClass: BackendClass) -> [RegisteredBackend] {
        entries.filter { $0.backendClass == backendClass }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The first-registered pm backend — what the single-backend UI surfaces
    /// (Settings connection status, "Open in <backend>", timeline PATCHes)
    /// reflect. nil in standalone mode.
    public var primaryPM: RegisteredBackend? {
        entries.first { $0.backendClass == .pm }
    }
}

/// Per-(session, backend) posting state. A MISSING ledger row reads as
/// `.pending` — rows are written at outcomes, so "never attempted" needs no
/// storage and the table only grows with actual posting activity.
public enum PostingState: String, Codable, Sendable {
    /// Not yet attempted (also the reading of an absent row).
    case pending
    /// The backend holds the entry (`entryID` when it reported one). Terminal.
    case posted
    /// Last attempt errored; retried on the next sync pass.
    case failed
    /// Deliberately not posted (sub-minute slice; billability flip closed it
    /// off). Terminal — the flip-history catch-up invoice is a future feature.
    case skipped
}

/// One posting-ledger row. The `(sessionID, backendID)` pair IS the
/// idempotency key: a retry can only ever update its own row, so no retry
/// path can double-post, and one backend's rows never gate another's — a
/// session can be `.posted` to one backend and `.pending` to a second at the
/// same moment. Replaces the single `pushedToOP`/`opTimeEntryID` slot (which
/// survives as a legacy mirror of the primary pm backend's row — see
/// `SyncEngine`).
public struct PostingRecord: Equatable, Codable, Sendable {
    public var sessionID: UUID
    public var backendID: String
    public var state: PostingState
    /// The backend-assigned entry id when posted (nil: backend replied
    /// without one, or the row is not `.posted`).
    public var entryID: RemoteEntryID?
    /// Human-readable last error while `.failed`.
    public var lastError: String?
    /// Failed attempts so far (diagnostics; no back-off policy yet).
    public var attempts: Int
    public var updatedAt: Date

    public init(sessionID: UUID, backendID: String, state: PostingState,
                entryID: RemoteEntryID? = nil, lastError: String? = nil,
                attempts: Int = 0, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.backendID = backendID
        self.state = state
        self.entryID = entryID
        self.lastError = lastError
        self.attempts = attempts
        self.updatedAt = updatedAt
    }
}

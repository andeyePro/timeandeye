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

/// What an entitlement-bearing (Pro) connector requires of the licence. A
/// cross-repo lockstep shape — andeyePro's connectors carry it, this
/// registry reads it (the locked cross-repo licence contract).
public struct BackendEntitlementRequirement: Equatable, Sendable {
    /// Minimum tier CLASS floor. A STANDARD connector (Xero) sets `.plus` —
    /// "any paid tier" — so the Plus-Lifetime key's one listed connector
    /// passes; only a genuinely premium/enterprise connector sets a higher
    /// floor. Never `.pro` for a standard connector (that would deny the
    /// flagship Plus SKU — the two-gate AND requires BOTH to pass).
    public let requiredTier: LicenseTier
    /// Stable connector id, matched against the key's signed `connectors[]`
    /// allowlist — authoritative for identity AND count.
    public let connectorID: String

    public init(requiredTier: LicenseTier, connectorID: String) {
        self.requiredTier = requiredTier
        self.connectorID = connectorID
    }
}

/// Why a registration was denied — drives the Settings copy ("QuickBooks
/// isn't included in your licence" / "QuickBooks needs Premium").
public enum EntitlementDenialReason: Equatable, Sendable {
    /// No licence at all: community never registers a Pro connector.
    case noLicense
    /// The connector id is not on the key's signed `connectors[]` allowlist.
    case notInConnectors
    /// Allow-listed, but the key's tier is below the connector's class floor.
    case tierBelowFloor(required: LicenseTier)
}

public enum EntitlementDecision: Equatable, Sendable {
    case allowed
    case denied(EntitlementDenialReason)
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

    /// The current licence (nil = community). Set by the app layer whenever
    /// the stored key is (re)validated; the entitlement gate reads it at
    /// registration time.
    public var license: License?

    /// Register (or replace — same id) a backend. Idempotent per id.
    /// This unguarded form is for community/built-in backends only — it is
    /// exactly `register(..., requires: nil)`.
    public func register(_ backend: any TaskBackend, id: String,
                         class backendClass: BackendClass) {
        entries.removeAll { $0.id == id }
        entries.append(RegisteredBackend(id: id, class: backendClass, backend: backend))
    }

    /// Entitlement-gated registration (spec §2.2). Both gates must pass —
    /// membership in the key's signed `connectors[]` AND the tier class
    /// floor (AND, fail-closed): neither can silently over-grant. A denial
    /// registers NOTHING (the backend never enters `entries`, so the sync
    /// fan-out never sees it — the same safe direction an unrecognised
    /// BackendClass already has) and returns the reason for Settings copy.
    @discardableResult
    public func register(_ backend: any TaskBackend, id: String,
                         class backendClass: BackendClass,
                         requires: BackendEntitlementRequirement?) -> EntitlementDecision {
        let decision = Self.entitlement(license: license, requires: requires)
        if decision == .allowed {
            register(backend, id: id, class: backendClass)
        }
        return decision
    }

    /// The pure gate, separated so checks (and Settings previews) can
    /// evaluate it without a registry. Fail-closed by construction: the only
    /// `.allowed` paths are the community backend (no requirement) and a
    /// licence that passes BOTH gates.
    public static func entitlement(license: License?,
                                   requires: BackendEntitlementRequirement?) -> EntitlementDecision {
        guard let requires else { return .allowed }            // community/built-in
        guard let license else { return .denied(.noLicense) }
        guard license.connectors.contains(requires.connectorID) else {
            return .denied(.notInConnectors)
        }
        guard license.tier >= requires.requiredTier else {
            return .denied(.tierBelowFloor(required: requires.requiredTier))
        }
        return .allowed
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
    /// off; a PERMANENT backend rejection — see PermanentPostError). Terminal
    /// — the flip-history catch-up invoice is a future feature.
    case skipped
    /// Quarantined: transient failures exceeded the retry cap
    /// (`SyncEngine.transientAttemptsCap`), so the row stopped damming the
    /// queue behind it. Excluded from eligibility like a terminal state;
    /// surfaced to the user; clearing the row retries. Old builds read this
    /// unknown rawValue as `.posted` — the never-double-post direction.
    case stuck
    /// The backend entry was DELETED by the amendment loop because its
    /// journal side went away (session deleted, or fully covered by
    /// higher-priority time). Terminal — but a stamp change that RESTORES
    /// the contribution re-opens it for a clean re-post. Old builds read
    /// the unknown rawValue as `.posted` (never-double-post).
    case retracted
    /// The journal moved but the backend REFUSES the amendment (entry frozen
    /// by invoicing). Terminal and surfaced in Posting health — the books
    /// and the journal genuinely disagree and only a human (credit note /
    /// invoice-unlock) can reconcile them.
    case diverged
    /// Intent written IMMEDIATELY BEFORE createTimeEntry goes on the wire.
    /// Normally overwritten within the same iteration (`.posted` on success,
    /// `.failed`/`.skipped` on error); a row still `.inflight` on a later
    /// pass means the process died in the create window and the backend may
    /// or may not hold the entry — the engine then VERIFIES (lists the
    /// backend) and adopts or retries, never blind re-creates (F12). Not
    /// eligible for posting while unresolved. Old builds read the unknown
    /// rawValue as `.posted` — never-double-post; the next new build's
    /// reconcile resolves it.
    case inflight
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
    /// Snapshot of what was ACTUALLY sent to the backend (the session's
    /// overlap-RESOLVED start/seconds at posting time). The divergence
    /// detector (D4) compares these against the current resolved session to
    /// know when the backend entry has drifted from the journal. nil on rows
    /// written before the snapshot existed, and on non-posting states.
    public var postedStart: Date?
    public var postedDuration: TimeInterval?
    /// The session REVISION's HLC stamp when this row was written/verified —
    /// "touched since" is `currentStamp != sessionStamp`, a pure content
    /// comparison. (Comparing a remote HLC's physical time against this
    /// device's wall clock broke both ways under skew: a behind-clock editor
    /// made resurrections invisible, an ahead-clock one re-verified every
    /// pass forever.) nil on pre-stamp rows and sync-off stores.
    public var sessionStamp: String?
    /// Non-nil = this entry is covered by a SENT invoice at the backend
    /// (the invoice-lock layer): the amendment loop must never touch it, and
    /// the UI shows the ref. Set by the engine's invoice poll; cleared ONLY
    /// by an explicit per-invoice unlock (deliberately sticky — a voided
    /// invoice doesn't silently re-open billed time; the human does).
    public var lockedInvoiceRef: String?

    public init(sessionID: UUID, backendID: String, state: PostingState,
                entryID: RemoteEntryID? = nil, lastError: String? = nil,
                attempts: Int = 0, updatedAt: Date = Date(),
                postedStart: Date? = nil, postedDuration: TimeInterval? = nil,
                sessionStamp: String? = nil, lockedInvoiceRef: String? = nil) {
        self.sessionID = sessionID
        self.backendID = backendID
        self.state = state
        self.entryID = entryID
        self.lastError = lastError
        self.attempts = attempts
        self.updatedAt = updatedAt
        self.postedStart = postedStart
        self.postedDuration = postedDuration
        self.sessionStamp = sessionStamp
        self.lockedInvoiceRef = lockedInvoiceRef
    }
}

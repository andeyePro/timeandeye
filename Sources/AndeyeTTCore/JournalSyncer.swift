import Foundation

/// Opaque incremental-pull cursor (CloudKit: the zone change token; the mock
/// server: a sequence number). The syncer never inspects it.
public struct SyncToken: Equatable, Codable, Sendable {
    public var raw: Data
    public init(raw: Data) { self.raw = raw }
}

/// The pipe to the shared truth (CloudKit private DB in production, an
/// in-memory server in checks). Implementations move revisions verbatim —
/// ALL merge intelligence stays in Core (SessionMerge/JournalSyncer), so the
/// checks exercise the real logic.
public protocol SyncTransport {
    /// Upload local revisions. The server applies record-level LWW, so a
    /// concurrent newer remote simply wins there and comes back on pull.
    func push(_ revisions: [SessionRevision]) async throws
    /// Revisions changed since `token` (nil = everything), plus the cursor to
    /// save for the next pull. Echoes of our own pushes may be included —
    /// applying them is an idempotent no-op.
    func pull(since token: SyncToken?) async throws -> (changes: [SessionRevision], token: SyncToken)
}

/// A replica's revision persistence: the raw synced truth (live + tombstones
/// + dirty flags). SQLiteJournalStore adopts this when sync lands; the
/// in-memory twin drives checks.
public protocol RevisionStore: AnyObject {
    func allRevisions() throws -> [SessionRevision]
    func revision(id: UUID) throws -> SessionRevision?
    func dirtyRevisionIDs() throws -> [UUID]
    /// Upsert from a LOCAL mutation: marks dirty (needs pushing).
    func saveLocal(_ revision: SessionRevision) throws
    /// Upsert from a REMOTE revision that won the merge: never dirty (it came
    /// from the server; pushing it back would be an echo).
    func applyRemote(_ revision: SessionRevision) throws
    /// Clear dirty ONLY where the stored revision still matches (same HLC) —
    /// a local edit that landed mid-push must stay dirty for the next cycle.
    func clearDirty(_ revisions: [SessionRevision]) throws
    /// Persisted pull cursor.
    var syncToken: SyncToken? { get set }
}

public final class InMemoryRevisionStore: RevisionStore {
    private var revisions: [UUID: SessionRevision] = [:]
    private var dirty: Set<UUID> = []
    public var syncToken: SyncToken?

    public init() {}

    public func allRevisions() throws -> [SessionRevision] {
        revisions.values.sorted {
            $0.session.start != $1.session.start
                ? $0.session.start < $1.session.start
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    public func revision(id: UUID) throws -> SessionRevision? { revisions[id] }

    public func dirtyRevisionIDs() throws -> [UUID] {
        dirty.sorted { $0.uuidString < $1.uuidString }
    }

    public func saveLocal(_ revision: SessionRevision) throws {
        revisions[revision.id] = revision
        dirty.insert(revision.id)
    }

    public func applyRemote(_ revision: SessionRevision) throws {
        revisions[revision.id] = revision
        dirty.remove(revision.id)   // the remote won; nothing of ours to push
    }

    public func clearDirty(_ cleared: [SessionRevision]) throws {
        for rev in cleared where revisions[rev.id]?.hlc == rev.hlc {
            dirty.remove(rev.id)
        }
    }
}

/// One replica's sync driver: pull → merge → push, all through SessionMerge,
/// so any two replicas that finish a cycle against the same server hold the
/// identical raw set (and therefore derive the identical journal view).
public final class JournalSyncer {
    private let store: RevisionStore
    private let transport: SyncTransport
    private let clock: HLCClock
    public var onDebug: (String) -> Void = { _ in }

    public init(store: RevisionStore, transport: SyncTransport, clock: HLCClock) {
        self.store = store
        self.transport = transport
        self.clock = clock
    }

    /// One full cycle. Pull first (so we never push something the server
    /// already obsoleted), then push what's still dirty after the merge.
    public func sync() async throws {
        // 1. Pull remote changes and fold them in by record-level LWW.
        let (changes, token) = try await transport.pull(since: store.syncToken)
        var applied = 0
        for remote in changes {
            clock.receive(remote.hlc)   // causality: our next edits order after
            let local = try store.revision(id: remote.id)
            let winner = SessionMerge.merge(local: local, remote: remote)
            guard let winner else { continue }
            if winner == remote, local != remote {
                try store.applyRemote(remote)
                applied += 1
            }
            // Local won: leave it (and its dirty flag) alone — push sends it.
        }
        store.syncToken = token
        // 2. Push everything still dirty.
        let dirtyIDs = try store.dirtyRevisionIDs()
        let outgoing = try dirtyIDs.compactMap { try store.revision(id: $0) }
        if !outgoing.isEmpty {
            try await transport.push(outgoing)
            try store.clearDirty(outgoing)
        }
        if applied > 0 || !outgoing.isEmpty {
            onDebug("sync: applied \(applied) remote, pushed \(outgoing.count)")
        }
    }
}

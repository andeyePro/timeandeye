import Foundation

/// Persistence boundary. In-memory here; the GRDB/SQLite implementation in the
/// macOS app must pass the JournalStore conformance checks.
public protocol JournalStore {
    func save(_ session: Session) throws
    func allSessions() throws -> [Session]
    /// A single session by id, without decoding every row — for edit/undo paths
    /// that previously did `allSessions().first(where: id==)` (a full-table
    /// decode to find one row).
    func session(id: UUID) throws -> Session?
    /// Total journalled sessions, and how many have been pushed — COUNT queries
    /// so the journal summary never decodes the whole table just to size it.
    func sessionCount() throws -> Int
    func pushedCount() throws -> Int
    /// (a) iCloud quota stewardship: the ACTUAL footprint, split honestly —
    /// `syncedBytes` is the JSON payload size of every live session (what
    /// really travels via CloudKit), `localDetailBytes` is the window-span
    /// detail table (local-only, never syncs). Real byte counts, not a
    /// per-row estimate/multiplier.
    func journalFootprint() throws -> (syncedBytes: Int, localDetailBytes: Int)
    /// Sessions overlapping [from, to), oldest first — the timeline's feed.
    func sessions(from: Date, to: Date) throws -> [Session]
    /// Each task's most recent session end (minus `excluding`, e.g. the live
    /// checkpoint row) — the durable-recency feed. An aggregate query, so it
    /// must never decode the whole table.
    func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date]
    /// LEGACY single-slot eligibility: certainty >= threshold, `pushedToOP`
    /// false, and on a remote (.op / .remote) task. Retained for the journal
    /// summary and behaviour-frozen checks; posting SELECTION now runs on the
    /// per-backend ledger (`sessions(needingPostTo:atOrAbove:)`).
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session]
    /// LEGACY single-slot mark, now the primary-pm MIRROR of a ledger row —
    /// it keeps `Session.pushedToOP`/`opTimeEntryID` (which timeline PATCH /
    /// delete / summary read) in step with the ledger.
    func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws

    // MARK: Posting ledger (per-session, per-backend)

    /// Every ledger row for a session, any backend. A backend with no row is
    /// `.pending` by definition.
    func postingRecords(session: UUID) throws -> [PostingRecord]
    /// One (session, backend) row; nil = never attempted (`.pending`).
    func postingRecord(session: UUID, backendID: String) throws -> PostingRecord?
    /// Upsert keyed by (sessionID, backendID) — the idempotency key. A retry
    /// can only ever update its own row.
    func setPostingRecord(_ record: PostingRecord) throws
    /// Remove one (session, backend) row so the session re-enters that
    /// backend's queue — the ledger analogue of resetting `pushedToOP` after
    /// a timeline delete/reassign.
    func clearPostingRecord(session: UUID, backendID: String) throws
    /// Every row for `backendID` in `state` — the crash-recovery sweep
    /// (`.inflight` rows a dead process left behind) reads this.
    func postingRecords(state: PostingState, backendID: String) throws -> [PostingRecord]
    /// Sessions eligible to post to ONE backend: certainty >= threshold, on a
    /// remote task (personal `.local` tasks never appear for ANY backend),
    /// and without a terminal (`posted`/`skipped`) row for `backendID`.
    /// `failed` rows are retryable and DO appear. Ledger keys are
    /// per-backend, so one backend's posted rows never hide a session from
    /// another backend.
    func sessions(needingPostTo backendID: String, atOrAbove threshold: Double) throws -> [Session]
    /// ONE-TIME upgrade from the single-slot fields: every `pushedToOP`
    /// session (minus `excluding`, e.g. the live-checkpoint sentinel) gains a
    /// `.posted` row against `backendID` carrying its `opTimeEntryID`, so the
    /// ledger-driven sync can never re-post history the old code already
    /// pushed. Idempotent per row (existing rows are never touched); returns
    /// how many rows were written.
    @discardableResult
    func migrateSingleSlotPostings(to backendID: String, excluding: Set<UUID>) throws -> Int
    // MARK: Resolved view (cross-device overlap resolution — D1)

    /// Sessions in [from, to] as the OVERLAP-RESOLVED derived view (see
    /// SessionMerge.resolveOverlaps): what display/aggregation/export show
    /// and what posting bills. Identical to `sessions(from:to:)` on stores
    /// without sync (single-device: nothing overlaps); the SQLite replica
    /// overrides it when the sync clock is attached.
    func resolvedSessions(from: Date, to: Date) throws -> [Session]
    /// One session's surviving (start, seconds) in the resolved view —
    /// what the posting engine should bill for it. nil when the session is
    /// fully covered by higher-priority overlapping time (post nothing).
    func resolvedContribution(sessionID: UUID) throws -> (start: Date, seconds: TimeInterval)?
    /// The session REVISION's current HLC stamp ("millis.counter@device"),
    /// nil when unstamped (sync off / no such row). The engine stores it on
    /// ledger rows and re-verifies a row only when the stamp CHANGES — a
    /// pure content comparison immune to cross-device clock skew.
    func sessionStamp(_ id: UUID) throws -> String?

    /// Timeline edits: replace the stored session (matched by id).
    func update(_ session: Session) throws
    func deleteSession(_ id: UUID) throws
    /// Escalate a slice's sync authority (auto → manual → edited) after a
    /// deliberate user action, so cross-device overlap resolution knows a
    /// human shaped it. Never downgrades. No-op on stores that aren't sync
    /// replicas (the in-memory store).
    func escalateOrigin(_ id: UUID, to origin: SliceOrigin) throws

    func save(_ segment: ReviewSegment) throws
    /// Unassigned review segments, oldest first.
    func pendingReview() throws -> [ReviewSegment]
    /// nil target = return the segments to the pending queue (undo).
    func assign(_ segmentIDs: [UUID], to target: Target?) throws

    /// Window-level activity detail for the timeline's zoom strip.
    func save(_ span: FocusSpan) throws
    func spans(from: Date, to: Date) throws -> [FocusSpan]

    /// Standalone comment-to-task storage: notes for tasks whose backend has
    /// no comment endpoint (Xero), no backend at all, or a `.local` task —
    /// the note must never silently vanish. Timestamped, newest last.
    func saveTaskComment(_ ref: TaskRef, text: String, at date: Date) throws
    func taskComments(for ref: TaskRef) throws -> [(date: Date, text: String)]

    // MARK: Invoice locks (the invoice-lock layer)

    /// Invoice refs the user explicitly UNLOCKED for `backendID`: the
    /// engine's poll must not re-apply a lock with the same ref (the backend
    /// keeps reporting the entry invoiced until a credit-note/void, which is
    /// the accountant's act — a NEW invoice ref locks again as normal).
    func unlockedInvoiceRefs(backendID: String) throws -> Set<String>
    func addUnlockedInvoiceRef(_ ref: String, backendID: String) throws

    // MARK: Retro-acceptance digests (approvals-drawer §3)

    /// Journal one retro-acceptance pass's receipt.
    func saveRetroDigest(_ digest: RetroDigest) throws
    /// Digests, newest first, capped at `limit` — the drawer's "Recently
    /// cleared" section. 30-day retention (see JournalStore's default).
    func retroDigests(limit: Int) throws -> [RetroDigest]
    /// Remove a digest row (undo has fully applied — nothing left to re-undo).
    func deleteRetroDigest(_ id: UUID) throws
}

public extension JournalStore {
    /// Default: no sync replica, nothing overlaps — the raw window IS the
    /// resolved view. (The SQLite store overrides when its clock is attached.)
    func resolvedSessions(from: Date, to: Date) throws -> [Session] {
        try sessions(from: from, to: to)
    }

    /// Default: the stored span is the contribution, whole.
    func resolvedContribution(sessionID: UUID) throws -> (start: Date, seconds: TimeInterval)? {
        guard let s = try session(id: sessionID) else { return nil }
        return (s.start, s.end.timeIntervalSince(s.start))
    }

    /// Default: no revision stamps — the verify sweep stays inert.
    func sessionStamp(_ id: UUID) throws -> String? { nil }

    /// Default footprint: real JSON-encoded byte counts via the existing
    /// read methods (no full-table decode cost concern for the in-memory
    /// store this serves). The SQLite replica overrides with a cheap SQL
    /// SUM(LENGTH(json)) instead.
    func journalFootprint() throws -> (syncedBytes: Int, localDetailBytes: Int) {
        let encoder = JSONEncoder()
        let synced = try allSessions().reduce(0) { $0 + ((try? encoder.encode($1).count) ?? 0) }
        let detail = try spans(from: .distantPast, to: .distantFuture)
            .reduce(0) { $0 + ((try? encoder.encode($1).count) ?? 0) }
        return (synced, detail)
    }

    /// Default: no-op, so a store/mock that doesn't implement retro digests
    /// (or a check double) keeps compiling and behaves as "nothing to show".
    func saveRetroDigest(_ digest: RetroDigest) throws {}
    func retroDigests(limit: Int) throws -> [RetroDigest] { [] }
    func deleteRetroDigest(_ id: UUID) throws {}
}

/// 30-day retention for retro-acceptance digests — a receipt trail, not an
/// archive (mirrors the spans table's own 30-day window in the SQLite store).
public let retroDigestRetentionDays = 30

public final class InMemoryJournalStore: JournalStore {
    private var sessions: [Session] = []
    private var segments: [ReviewSegment] = []
    private var allSpans: [FocusSpan] = []
    private var comments: [String: [(date: Date, text: String)]] = [:]
    /// Posting ledger keyed "sessionID|backendID" — the idempotency key.
    private var ledger: [String: PostingRecord] = [:]
    /// Per-backend invoice refs the user unlocked (never auto re-locked).
    private var unlockedInvoices: [String: Set<String>] = [:]
    private var retroDigestRows: [RetroDigest] = []

    private func ledgerKey(_ session: UUID, _ backendID: String) -> String {
        "\(session.uuidString)|\(backendID)"
    }

    public init() {}

    public func save(_ session: Session) throws {
        sessions.append(session)
    }

    public func allSessions() throws -> [Session] {
        sessions
    }

    public func session(id: UUID) throws -> Session? {
        sessions.first { $0.id == id }
    }

    public func sessionCount() throws -> Int {
        sessions.count
    }

    public func pushedCount() throws -> Int {
        sessions.filter(\.pushedToOP).count
    }

    public func sessions(from: Date, to: Date) throws -> [Session] {
        sessions.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    }

    public func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date] {
        var out: [TaskRef: Date] = [:]
        for s in sessions where !excluding.contains(s.id) {
            out[s.task] = max(out[s.task] ?? .distantPast, s.end)
        }
        return out
    }

    public func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        sessions.filter { session in
            guard session.task.isRemote else { return false }
            return !session.pushedToOP && session.certainty >= threshold
        }
    }

    public func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].pushedToOP = true
        sessions[i].opTimeEntryID = opTimeEntryID
    }

    // MARK: Posting ledger

    public func postingRecords(session: UUID) throws -> [PostingRecord] {
        ledger.values.filter { $0.sessionID == session }
            .sorted { $0.backendID < $1.backendID }
    }

    public func postingRecord(session: UUID, backendID: String) throws -> PostingRecord? {
        ledger[ledgerKey(session, backendID)]
    }

    public func setPostingRecord(_ record: PostingRecord) throws {
        ledger[ledgerKey(record.sessionID, record.backendID)] = record
    }

    public func clearPostingRecord(session: UUID, backendID: String) throws {
        ledger[ledgerKey(session, backendID)] = nil
    }

    public func postingRecords(state: PostingState, backendID: String) throws -> [PostingRecord] {
        ledger.values.filter { $0.state == state && $0.backendID == backendID }
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    public func unlockedInvoiceRefs(backendID: String) throws -> Set<String> {
        unlockedInvoices[backendID] ?? []
    }

    public func addUnlockedInvoiceRef(_ ref: String, backendID: String) throws {
        unlockedInvoices[backendID, default: []].insert(ref)
    }

    public func sessions(needingPostTo backendID: String,
                         atOrAbove threshold: Double) throws -> [Session] {
        sessions.filter { session in
            guard session.task.isRemote, session.certainty >= threshold else { return false }
            // FAIL-CLOSED: only .failed (and no row at all) is retryable;
            // every other state — including any future one — blocks.
            switch ledger[ledgerKey(session.id, backendID)]?.state {
            case .failed, .pending, nil: return true
            default: return false
            }
        }
        .sorted { $0.start < $1.start }
    }

    public func migrateSingleSlotPostings(to backendID: String,
                                          excluding: Set<UUID>) throws -> Int {
        var migrated = 0
        for session in sessions
        where session.pushedToOP && session.task.isRemote && !excluding.contains(session.id) {
            let key = ledgerKey(session.id, backendID)
            guard ledger[key] == nil else { continue }
            ledger[key] = PostingRecord(sessionID: session.id, backendID: backendID,
                                        state: .posted, entryID: session.opTimeEntryID)
            migrated += 1
        }
        return migrated
    }

    public func update(_ session: Session) throws {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i] = session
    }

    public func deleteSession(_ id: UUID) throws {
        sessions.removeAll { $0.id == id }
    }

    public func escalateOrigin(_ id: UUID, to origin: SliceOrigin) throws {
        // Not a sync replica: origin has no effect here.
    }

    public func save(_ span: FocusSpan) throws {
        allSpans.append(span)
    }

    public func spans(from: Date, to: Date) throws -> [FocusSpan] {
        allSpans.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    }

    public func save(_ segment: ReviewSegment) throws {
        segments.append(segment)
    }

    public func pendingReview() throws -> [ReviewSegment] {
        segments.filter { $0.assigned == nil }.sorted { $0.start < $1.start }
    }

    public func assign(_ segmentIDs: [UUID], to target: Target?) throws {
        let ids = Set(segmentIDs)
        for i in segments.indices where ids.contains(segments[i].id) {
            segments[i].assigned = target
        }
    }

    public func saveTaskComment(_ ref: TaskRef, text: String, at date: Date) throws {
        comments[ref.storageKey, default: []].append((date, text))
    }

    public func taskComments(for ref: TaskRef) throws -> [(date: Date, text: String)] {
        (comments[ref.storageKey] ?? []).sorted { $0.date < $1.date }
    }

    // MARK: Retro-acceptance digests

    private func pruneRetroDigests(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(retroDigestRetentionDays) * 86_400)
        retroDigestRows.removeAll { $0.date < cutoff }
    }

    public func saveRetroDigest(_ digest: RetroDigest) throws {
        pruneRetroDigests()
        retroDigestRows.removeAll { $0.id == digest.id }
        retroDigestRows.append(digest)
    }

    public func retroDigests(limit: Int) throws -> [RetroDigest] {
        pruneRetroDigests()
        return Array(retroDigestRows.sorted { $0.date > $1.date }.prefix(limit))
    }

    public func deleteRetroDigest(_ id: UUID) throws {
        retroDigestRows.removeAll { $0.id == id }
    }
}

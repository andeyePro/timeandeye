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
    /// Sessions overlapping [from, to), oldest first — the timeline's feed.
    func sessions(from: Date, to: Date) throws -> [Session]
    /// Each task's most recent session end (minus `excluding`, e.g. the live
    /// checkpoint row) — the durable-recency feed. An aggregate query, so it
    /// must never decode the whole table.
    func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date]
    /// Sessions eligible for OP push: certainty >= threshold, not yet pushed,
    /// and on an `.op` task (local-only tasks never push).
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session]
    func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws
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
}

public final class InMemoryJournalStore: JournalStore {
    private var sessions: [Session] = []
    private var segments: [ReviewSegment] = []
    private var allSpans: [FocusSpan] = []

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
            guard case .op = session.task else { return false }
            return !session.pushedToOP && session.certainty >= threshold
        }
    }

    public func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].pushedToOP = true
        sessions[i].opTimeEntryID = opTimeEntryID
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
}

import Foundation

/// Persistence boundary. In-memory here; the GRDB/SQLite implementation in the
/// macOS app must pass the JournalStore conformance checks.
public protocol JournalStore {
    func save(_ session: Session) throws
    func allSessions() throws -> [Session]
    /// Sessions eligible for OP push: certainty >= threshold, not yet pushed,
    /// and on an `.op` task (local-only tasks never push).
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session]
    func markPushed(_ id: UUID) throws

    func save(_ segment: ReviewSegment) throws
    /// Unassigned review segments, oldest first.
    func pendingReview() throws -> [ReviewSegment]
    func assign(_ segmentIDs: [UUID], to target: Target) throws
}

public final class InMemoryJournalStore: JournalStore {
    private var sessions: [Session] = []
    private var segments: [ReviewSegment] = []

    public init() {}

    public func save(_ session: Session) throws {
        sessions.append(session)
    }

    public func allSessions() throws -> [Session] {
        sessions
    }

    public func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        sessions.filter { session in
            guard case .op = session.task else { return false }
            return !session.pushedToOP && session.certainty >= threshold
        }
    }

    public func markPushed(_ id: UUID) throws {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].pushedToOP = true
    }

    public func save(_ segment: ReviewSegment) throws {
        segments.append(segment)
    }

    public func pendingReview() throws -> [ReviewSegment] {
        segments.filter { $0.assigned == nil }.sorted { $0.start < $1.start }
    }

    public func assign(_ segmentIDs: [UUID], to target: Target) throws {
        let ids = Set(segmentIDs)
        for i in segments.indices where ids.contains(segments[i].id) {
            segments[i].assigned = target
        }
    }
}

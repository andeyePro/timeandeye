import Foundation

/// One pending segment the retro pass auto-clears — its best-scored target
/// met (or beat) the retro bar.
public struct RetroClearance: Equatable, Sendable {
    public var segmentID: UUID
    public var target: Target
    public var score: Double

    public init(segmentID: UUID, target: Target, score: Double) {
        self.segmentID = segmentID
        self.target = target
        self.score = score
    }
}

/// A session whose certainty the retro pass raises because it overlaps a
/// cleared segment. Certainty only ever moves up (open question (d)/(e), the
/// 2026-07-06 approvals-drawer spec: retro-clearing lifts the session too, so
/// it becomes push-eligible through the normal sync path).
public struct SessionLift: Equatable, Sendable {
    public var sessionID: UUID
    public var priorTask: TaskRef
    public var priorCertainty: Double
    public var newTask: TaskRef
    public var newCertainty: Double

    public init(sessionID: UUID, priorTask: TaskRef, priorCertainty: Double,
                newTask: TaskRef, newCertainty: Double) {
        self.sessionID = sessionID
        self.priorTask = priorTask
        self.priorCertainty = priorCertainty
        self.newTask = newTask
        self.newCertainty = newCertainty
    }
}

public struct RetroPlan: Equatable, Sendable {
    public var clearances: [RetroClearance]
    public var lifts: [SessionLift]

    public init(clearances: [RetroClearance] = [], lifts: [SessionLift] = []) {
        self.clearances = clearances
        self.lifts = lifts
    }
}

/// Retroactive auto-acceptance (approvals-drawer spec §3): when a later
/// pin/rule/correction makes the attributor confident about a queued drawer
/// row, clear it without waiting for a human tap — and lift the overlapping
/// low-certainty session so it posts through the normal sync path too. Pure
/// planning only: the caller (AppController) applies the plan through the
/// journal; nothing here touches an Attributor or a store, so it needs no
/// mocking to check.
public enum RetroAcceptance {
    /// `score` is the caller's scoring closure — in production, the
    /// attributor's own `explain()`/rank path (reused, not reinvented), so a
    /// retro clearance can never disagree with what a human would see if they
    /// opened that row right now.
    ///
    /// A segment clears when its best score is `>= bar` (borderline segments,
    /// score == bar − ε, stay queued). A session lifts only when it overlaps
    /// a CLEARED segment's `[start, end]` AND its own certainty is still
    /// below `bar` — and only when the retro target is a real task: a
    /// `.doNotTrack` clearance has nothing a `Session` can represent (its
    /// `task` is a `TaskRef`, not a `Target`), so it clears the drawer row
    /// without touching any session. Certainty is set to
    /// `max(current, score)` — never lowered. A session overlapping several
    /// cleared segments keeps the highest-scoring lift.
    public static func plan(pending: [ReviewSegment], sessions: [Session], bar: Double,
                            score: (ActivitySignal) -> (target: Target, score: Double)?) -> RetroPlan {
        var clearances: [RetroClearance] = []
        for segment in pending {
            let signal = ActivitySignal(app: segment.app, windowTitle: segment.windowTitle,
                                        tabURL: segment.tabURL, timestamp: segment.start)
            guard let result = score(signal), result.score >= bar else { continue }
            clearances.append(RetroClearance(segmentID: segment.id, target: result.target,
                                             score: result.score))
        }
        guard !clearances.isEmpty else { return RetroPlan() }

        let segmentsByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        var bestLift: [UUID: SessionLift] = [:]
        for clearance in clearances {
            guard case .task(let ref) = clearance.target,
                  let segment = segmentsByID[clearance.segmentID] else { continue }
            for session in sessions
            where session.certainty < bar
                && session.start < segment.end && session.end > segment.start {
                let newCertainty = max(session.certainty, clearance.score)
                if let existing = bestLift[session.id], existing.newCertainty >= newCertainty {
                    continue
                }
                bestLift[session.id] = SessionLift(sessionID: session.id, priorTask: session.task,
                                                   priorCertainty: session.certainty,
                                                   newTask: ref, newCertainty: newCertainty)
            }
        }
        // Stable order: the sessions array's own order, not dictionary order.
        let lifts = sessions.compactMap { bestLift[$0.id] }
        return RetroPlan(clearances: clearances, lifts: lifts)
    }
}

/// Journalled, undoable receipt of one retro-acceptance pass — "Cleared N
/// items — undo", surviving relaunch (a session-bounded UndoStack entry isn't
/// enough here: the drawer's own "Recently cleared" section reads this back).
public struct RetroDigest: Codable, Equatable, Sendable, Identifiable {
    /// One session's state immediately before a lift — the undo payload.
    /// (An equivalent Codable stand-in for the `(id, task, certainty)` tuple
    /// the spec describes — Swift tuples aren't Codable.)
    public struct PriorSessionState: Codable, Equatable, Sendable {
        public var id: UUID
        public var task: TaskRef
        public var certainty: Double

        public init(id: UUID, task: TaskRef, certainty: Double) {
            self.id = id
            self.task = task
            self.certainty = certainty
        }
    }

    public var id: UUID
    public var date: Date
    public var clearedSegmentIDs: [UUID]
    public var target: Target
    public var count: Int
    public var reason: String
    public var priorSessions: [PriorSessionState]

    public init(id: UUID = UUID(), date: Date = Date(), clearedSegmentIDs: [UUID],
                target: Target, count: Int, reason: String,
                priorSessions: [PriorSessionState]) {
        self.id = id
        self.date = date
        self.clearedSegmentIDs = clearedSegmentIDs
        self.target = target
        self.count = count
        self.reason = reason
        self.priorSessions = priorSessions
    }
}

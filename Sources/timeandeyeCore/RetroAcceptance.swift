import Foundation

/// The ONE low-certainty eligibility gate every retro-style pass shares
/// (attribution-calculus spec §thresholds: "one shared predicate — unpushed,
/// below the bar, overlapping the segment — so the three paths cannot
/// drift"). Used by `RetroAcceptance.plan`'s lift gate, `UnknownSweep`, and
/// `ReviewConfirm.plan`. ReviewConfirm layers its own `!claimed` on top; the
/// unpushed + below-bar + overlap core is identical everywhere.
package enum RetroEligibility {
    /// Does the session's `[start, end)` overlap `[segStart, segEnd)`?
    package static func overlaps(_ session: Session, _ segStart: Date, _ segEnd: Date) -> Bool {
        session.start < segEnd && session.end > segStart
    }

    /// Unpushed, below `bar`, and overlapping the one segment `[segStart, segEnd)`.
    package static func eligible(_ session: Session, below bar: Double,
                                segStart: Date, segEnd: Date) -> Bool {
        !session.pushedToOP && session.certainty < bar
            && overlaps(session, segStart, segEnd)
    }

    /// Unpushed, below `bar`, and overlapping ANY of `segments`.
    package static func eligible(_ session: Session, below bar: Double,
                                anyOf segments: [ReviewSegment]) -> Bool {
        !session.pushedToOP && session.certainty < bar
            && segments.contains { overlaps(session, $0.start, $0.end) }
    }
}

/// One pending segment the retro pass auto-clears — its best-scored target
/// met (or beat) the retro bar.
package struct RetroClearance: Equatable, Sendable {
    package var segmentID: UUID
    package var target: Target
    package var score: Double

    package init(segmentID: UUID, target: Target, score: Double) {
        self.segmentID = segmentID
        self.target = target
        self.score = score
    }
}

/// A session whose certainty the retro pass raises because it overlaps a
/// cleared segment. Certainty only ever moves up (open question (d)/(e), the
/// 2026-07-06 approvals-drawer spec: retro-clearing lifts the session too, so
/// it becomes push-eligible through the normal sync path).
package struct SessionLift: Equatable, Sendable {
    package var sessionID: UUID
    package var priorTask: TaskRef
    package var priorCertainty: Double
    package var newTask: TaskRef
    package var newCertainty: Double

    package init(sessionID: UUID, priorTask: TaskRef, priorCertainty: Double,
                newTask: TaskRef, newCertainty: Double) {
        self.sessionID = sessionID
        self.priorTask = priorTask
        self.priorCertainty = priorCertainty
        self.newTask = newTask
        self.newCertainty = newCertainty
    }
}

package struct RetroPlan: Equatable, Sendable {
    package var clearances: [RetroClearance]
    package var lifts: [SessionLift]

    package init(clearances: [RetroClearance] = [], lifts: [SessionLift] = []) {
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
package enum RetroAcceptance {
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
    package static func plan(pending: [ReviewSegment], sessions: [Session], bar: Double,
                            score: (ActivitySignal) -> (target: Target, score: Double)?) -> RetroPlan {
        var clearances: [RetroClearance] = []
        for segment in pending {
            // The row's own reconstruction (`ReviewSegment.signal`) carries
            // its stored email evidence, so a rule keyed on a correspondent/
            // domain/subject — e.g. one the grain footer just wrote — can
            // retro-clear the OTHER rows from that counterparty, exactly as
            // it would score them if the user opened each one now.
            guard let result = score(segment.signal), result.score >= bar else { continue }
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
            where RetroEligibility.eligible(session, below: bar,
                                            segStart: segment.start, segEnd: segment.end) {
                // OWNERSHIP (spec §The ownership rule): the lift re-points the
                // session to the cleared target `ref`. The gate guarantees the
                // session is below `bar` and the clearance guarantees its score
                // is at or above `bar`, so `max(current, score) == score`
                // ALWAYS here — the lift REPLACES certainty with the new
                // target's own score (honouring "task change ⇒ replace") while
                // reading as the monotone-up form the spec lists for a same-task
                // re-affirmation. Both collapse to `score` under this gate.
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

/// One session the Unknown sweep re-points — its prior task, for undo.
package struct UnknownRepoint: Equatable, Sendable {
    package var sessionID: UUID
    package var priorTask: TaskRef
    /// The session's certainty before the sweep — the sweep writes the
    /// human-word 1.0 (the user filed it as Unknown), so the undo must put the
    /// exact prior number back.
    package var priorCertainty: Double
    /// What decided the session before the sweep — restored on ⌘Z so the
    /// undo really is "as it stood" (in-memory only, like the repoint).
    package var priorProvenance: SessionProvenance?

    package init(sessionID: UUID, priorTask: TaskRef, priorCertainty: Double = 0,
                priorProvenance: SessionProvenance? = nil) {
        self.sessionID = sessionID
        self.priorTask = priorTask
        self.priorCertainty = priorCertainty
        self.priorProvenance = priorProvenance
    }
}

/// Unknown task category (2026-07-09), §4: when a review stack sweeps to
/// Unknown, its overlapping UNPUSHED low-certainty sessions re-point to the
/// Unknown task too — otherwise the drawer row would clear while the actual
/// tracked time kept pointing at the old guessed task. Sweeping is a HUMAN
/// gesture ("I don't know what this was — file it as Unknown"), so the
/// controller writes the human-word certainty (1.0) at apply time, exactly as
/// a review confirm does (spec §The three tiers: Unknown-sweep repoint is a
/// human-word producer) — NOT the engine's lift-to-max shape. This planning
/// step only names WHICH sessions repoint; the human-word write lives in the
/// controller. Pure: the caller (AppController) applies the repoint through
/// the journal.
package enum UnknownSweep {
    /// A session qualifies when it overlaps ANY of the just-swept segments,
    /// hasn't posted yet, and is still below `bar` — the one shared retro
    /// eligibility gate (`RetroEligibility`), same as the retro lift and the
    /// review confirm.
    package static func sessionsToRepoint(segments: [ReviewSegment], sessions: [Session],
                                         bar: Double) -> [UnknownRepoint] {
        sessions.filter { RetroEligibility.eligible($0, below: bar, anyOf: segments) }
            .map { UnknownRepoint(sessionID: $0.id, priorTask: $0.task,
                                  priorCertainty: $0.certainty,
                                  priorProvenance: $0.provenance) }
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
        /// Pre-lift provenance, restored on undo. Optional so digests saved
        /// before 2026-07-10 keep decoding (synthesized decodeIfPresent).
        public var priorProvenance: SessionProvenance?
        /// Whether the slice was POSTED before the lift/refile. A refile of a
        /// posted slice deletes its backend entry, so undo can't resurrect the
        /// dead id — it re-posts under the restored task instead. Optional so
        /// digests saved before this field keep decoding; nil reads as false.
        public var priorPushedToOP: Bool?

        public init(id: UUID, task: TaskRef, certainty: Double,
                    priorProvenance: SessionProvenance? = nil,
                    priorPushedToOP: Bool? = nil) {
            self.id = id
            self.task = task
            self.certainty = certainty
            self.priorProvenance = priorProvenance
            self.priorPushedToOP = priorPushedToOP
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

import Foundation

/// Mis-filed-slice handling (Martin's design, approved 2026-07-11 at 296):
/// when later corrections or rules make TODAY'S derivation confidently
/// contradict a journalled slice, the engine acts instead of silently
/// knowing better — the why-panel's "today's rules would say" line grew
/// hands. Provenance-gated throughout:
///
///   - Slices the USER decided (assigned, AI-applied, pinned, categorised)
///     are never touched and never nagged — their word outranks the rules.
///   - ENGINE-decided slices refile automatically when today's answer is at
///     or above the auto-push bar and the slice hasn't posted — batched
///     into the same undoable digest the retro pass uses, so being right
///     costs nothing and being wrong costs one undo.
///   - Posted (and therefore invoice-lockable) slices are FLAGGED, never
///     moved — money doesn't move off the back of a bulk pass.
///   - Below the bar — or when the slice predates provenance journalling,
///     where "engine-decided" cannot be proven — it's a suggestion only:
///     one review row, refile-all or dismiss-for-good.
/// How the engine treats past entries that later evidence contradicts
///: update them automatically, leave them entirely alone,
/// or queue every contradiction for his review. String-raw + lenient
/// decode like every settings enum.
public enum RefileMode: String, Codable, CaseIterable, Sendable {
    case auto      // update past entries when certainty changes
    case off       // never touch (or mention) past entries
    case review    // everything becomes a suggestion to confirm
}

public enum ContradictionRefile {

    public struct Finding: Equatable, Sendable {
        public var sessionID: UUID
        public var priorTask: TaskRef
        public var priorCertainty: Double
        public var priorProvenance: SessionProvenance?
        public var newTask: TaskRef
        public var score: Double

        public init(sessionID: UUID, priorTask: TaskRef, priorCertainty: Double,
                    priorProvenance: SessionProvenance?, newTask: TaskRef,
                    score: Double) {
            self.sessionID = sessionID
            self.priorTask = priorTask
            self.priorCertainty = priorCertainty
            self.priorProvenance = priorProvenance
            self.newTask = newTask
            self.score = score
        }

        /// Stable dismissal key: a session dismissed for ONE suggested task
        /// may legitimately resurface if the rules later point somewhere else.
        public var dismissalKey: String { "\(sessionID.uuidString)|\(newTask.storageKey)" }
    }

    public struct Plan: Equatable, Sendable {
        /// ≥ bar, provably engine-decided, unpushed: refile now.
        public var refiles: [Finding]
        /// Contradicted at/above the bar but already posted: flag only.
        public var postedFlags: [Finding]
        /// Suggest-only: below the bar, or provenance unknown.
        public var suggestions: [Finding]

        public init(refiles: [Finding] = [], postedFlags: [Finding] = [],
                    suggestions: [Finding] = []) {
            self.refiles = refiles
            self.postedFlags = postedFlags
            self.suggestions = suggestions
        }

        public var isEmpty: Bool {
            refiles.isEmpty && postedFlags.isEmpty && suggestions.isEmpty
        }
    }

    /// Provenance raws that are the USER's word — never touched.
    public static let userDecided: Set<String> = [
        "userAssigned", "aiApplied", "pin", "sessionSticky",
    ]

    /// `score` re-derives the slice's best answer at its own moment (the
    /// controller feeds the dominant span through the attributor's explain
    /// path — same numbers a human sees opening the card). `suggestFloor`
    /// keeps noise out of the suggestion row (the review threshold is the
    /// natural choice). `dismissed` holds `Finding.dismissalKey` strings.
    public static func plan(sessions: [Session], bar: Double, suggestFloor: Double,
                            dismissed: Set<String>,
                            score: (Session) -> (target: Target, score: Double)?) -> Plan {
        var plan = Plan()
        for session in sessions {
            let provenanceRaw = session.provenance?.sourceRaw
            if let provenanceRaw, userDecided.contains(provenanceRaw) { continue }
            guard let result = score(session),
                  case .task(let newRef) = result.target,
                  newRef != session.task,
                  result.score >= suggestFloor else { continue }
            let finding = Finding(sessionID: session.id, priorTask: session.task,
                                  priorCertainty: session.certainty,
                                  priorProvenance: session.provenance,
                                  newTask: newRef, score: result.score)
            if dismissed.contains(finding.dismissalKey) { continue }
            let provablyEngine = provenanceRaw != nil
            if result.score >= bar && provablyEngine {
                if session.pushedToOP {
                    plan.postedFlags.append(finding)
                } else {
                    plan.refiles.append(finding)
                }
            } else {
                plan.suggestions.append(finding)
            }
        }
        return plan
    }
}

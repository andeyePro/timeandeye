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
///     moved — money doesn't move off the back of a bulk pass, whatever the
///     score or provenance. This lane takes precedence over the two below.
///   - An unpushed slice below the bar — or one that predates provenance
///     journalling, where "engine-decided" cannot be proven — is a suggestion
///     only: one review row, refile-all or dismiss-for-good.
/// How the engine treats past entries that later evidence contradicts
///: update them automatically, leave them entirely alone,
/// or queue every contradiction for his review. String-raw + lenient
/// decode like every settings enum.
package enum RefileMode: String, Codable, CaseIterable, Sendable {
    case auto      // update past entries when certainty changes
    case off       // never touch (or mention) past entries
    case review    // everything becomes a suggestion to confirm
}

package enum ContradictionRefile {

    package struct Finding: Equatable, Sendable {
        package var sessionID: UUID
        package var priorTask: TaskRef
        package var priorCertainty: Double
        package var newTask: TaskRef
        package var score: Double

        package init(sessionID: UUID, priorTask: TaskRef, priorCertainty: Double,
                    newTask: TaskRef, score: Double) {
            self.sessionID = sessionID
            self.priorTask = priorTask
            self.priorCertainty = priorCertainty
            self.newTask = newTask
            self.score = score
        }

        /// Stable dismissal key: a session dismissed for ONE suggested task
        /// may legitimately resurface if the rules later point somewhere else.
        package var dismissalKey: String { "\(sessionID.uuidString)|\(newTask.storageKey)" }
    }

    package struct Plan: Equatable, Sendable {
        /// ≥ bar, provably engine-decided, unpushed: refile now.
        package var refiles: [Finding]
        /// Already posted (invoice-lockable): flag only, whatever the score or
        /// provenance — money never moves off a bulk pass.
        package var postedFlags: [Finding]
        /// Suggest-only: unpushed, and below the bar or provenance unknown.
        package var suggestions: [Finding]

        package init(refiles: [Finding] = [], postedFlags: [Finding] = [],
                    suggestions: [Finding] = []) {
            self.refiles = refiles
            self.postedFlags = postedFlags
            self.suggestions = suggestions
        }

        package var isEmpty: Bool {
            refiles.isEmpty && postedFlags.isEmpty && suggestions.isEmpty
        }
    }

    /// Provenance raws that are the USER's word — never touched.
    package static let userDecided: Set<String> = [
        "userAssigned", "aiApplied", "pin", "sessionSticky",
    ]

    /// The linkage transition when a finding is applied to a session.
    /// Factored out of `AppController.applyRefiles` so the two rules that
    /// used to be wrong there are pinned in Core:
    ///   * certainty becomes the RE-DERIVED score — never `max(old, new)`.
    ///     The old task's confidence must not inflate the new target's.
    ///   * a POSTED slice must shed its backend linkage before it re-points,
    ///     exactly the delete-and-clear hygiene applyTimelineEdit /
    ///     reassignTimelineSessions run: the old entry belongs to the old
    ///     work package, so it is deleted and the time re-posts under the
    ///     new task. An unpushed slice has no backend footprint to clear.
    package struct Applied: Equatable, Sendable {
        package var newTask: TaskRef
        package var certainty: Double
        package var severBackendLinkage: Bool
        package var entryToDelete: RemoteEntryID?

        package init(newTask: TaskRef, certainty: Double,
                    severBackendLinkage: Bool, entryToDelete: RemoteEntryID?) {
            self.newTask = newTask
            self.certainty = certainty
            self.severBackendLinkage = severBackendLinkage
            self.entryToDelete = entryToDelete
        }
    }

    package static func apply(_ finding: Finding, to session: Session) -> Applied {
        Applied(newTask: finding.newTask,
                certainty: finding.score,
                severBackendLinkage: session.pushedToOP,
                entryToDelete: session.pushedToOP ? session.opTimeEntryID : nil)
    }

    /// `score` re-derives the slice's best answer at its own moment (the
    /// controller feeds the dominant span through the attributor's explain
    /// path — same numbers a human sees opening the card). `suggestFloor`
    /// keeps noise out of the suggestion row (the review threshold is the
    /// natural choice). `dismissed` holds `Finding.dismissalKey` strings.
    package static func plan(sessions: [Session], bar: Double, suggestFloor: Double,
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
                                  newTask: newRef, score: result.score)
            if dismissed.contains(finding.dismissalKey) { continue }
            let provablyEngine = provenanceRaw != nil
            // A posted (invoice-lockable) slice is FLAGGED, never actioned —
            // money never moves off a bulk pass, whatever the score or the
            // provenance. This must precede the refile/suggest split: a posted
            // slice with nil provenance or a below-bar score would otherwise
            // fall through to suggestions, where "Refile all" deletes billed
            // time. Deliberate per-slice moves stay on the timeline-edit path.
            if session.pushedToOP {
                plan.postedFlags.append(finding)
            } else if result.score >= bar && provablyEngine {
                plan.refiles.append(finding)
            } else {
                plan.suggestions.append(finding)
            }
        }
        return plan
    }
}

import Foundation

/// The correction ledger's REVERSE index (13 Aug reply 9: "showing me what
/// has been corrected based on what correction"): which journalled slices a
/// given correction has since decided. Computed at view time from the
/// journal rather than plumbed through persisted schemas — for
/// prime-decided slices the match is exact (the prime's key IS the
/// correction's surface); for ranked-decided ones any attribution is the
/// blend of many corrections, so a stored back-pointer would be no less
/// approximate than the same-surface/same-app read used here, and this way
/// no store changes shape.
package enum CorrectionImpact {

    package struct Hit: Equatable, Sendable {
        package var sessionID: UUID
        package var start: Date
        package var end: Date
        /// True when the slice's deciding surface matched the correction's
        /// exactly (a prime firing); false = same app + same task under a
        /// ranked decision — the honest "pulled by corrections like this
        /// one" read.
        package var exactSurface: Bool

        package var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    package struct Summary: Equatable, Sendable {
        package var hits: [Hit]
        package var totalSeconds: TimeInterval
        package var isEmpty: Bool { hits.isEmpty }

        package init(hits: [Hit], totalSeconds: TimeInterval) {
            self.hits = hits
            self.totalSeconds = totalSeconds
        }
    }

    /// Engine sources a correction can have decided THROUGH. Human verbs
    /// (userAssigned, walkConfirm's stamp, …) are the user's own word, and
    /// rules have their own ledger rows — neither is a correction's doing.
    private static let engineSources: Set<String> = [
        AttributionExplanation.Source.primedSurface.rawValue,
        AttributionExplanation.Source.ranked.rawValue,
    ]

    /// Which of `sessions` (each paired with its deciding surface, from its
    /// dominant span) this `record` has since decided.
    package static func summary(for record: CorrectionLedger.Record,
                               sessions: [(session: Session, surface: Surface?)])
        -> Summary {
        guard case .task(let taught) = record.target else {
            return Summary(hits: [], totalSeconds: 0)
        }
        let key = record.surface
        var hits: [Hit] = []
        for entry in sessions {
            let s = entry.session
            guard s.start >= record.at,
                  s.task == taught,
                  let raw = s.provenance?.sourceRaw,
                  engineSources.contains(raw),
                  let surface = entry.surface else { continue }
            if surface == key {
                hits.append(Hit(sessionID: s.id, start: s.start, end: s.end,
                                exactSurface: true))
            } else if raw == AttributionExplanation.Source.ranked.rawValue,
                      surface.app.lowercased() == record.app.lowercased() {
                hits.append(Hit(sessionID: s.id, start: s.start, end: s.end,
                                exactSurface: false))
            }
        }
        hits.sort { $0.start > $1.start }
        return Summary(hits: hits, totalSeconds: hits.reduce(0) { $0 + $1.seconds })
    }

}

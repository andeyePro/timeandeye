import Foundation

/// Away-mode recovery, the MORE-AUTO shape Martin chose (13 Aug reply 2,
/// answering the design question the 2026-08-07 recording work left open):
/// the engine replays the focus evidence recorded while Away was pinned
/// (`FocusSpan.observedWhileAway` rows) and proposes a rebuilt timeline for
/// the user to confirm — the rescue for a forgotten toggle, where at-computer
/// work sat absorbed into the pinned task.
///
/// Pure planning only: the caller supplies the evidence, the stretch, and
/// the engine (an `attribute` closure wrapping `Attributor.explain` at the
/// span's own timestamp). Applying a confirmed plan goes through the
/// controller's existing split/reassign machinery so posting locks and
/// compensation laws hold unchanged.
package enum AwayRescue {

    /// One proposed slice of the rebuilt timeline.
    package struct Proposal: Equatable, Sendable {
        package var start: Date
        package var end: Date
        package var target: Target
        package var certainty: Double
        package var provenance: SessionProvenance?
        /// Display hint: the dominant app of the merged run.
        package var app: String

        package var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    package struct Plan: Equatable, Sendable {
        /// Re-attributable stretches, in time order, clipped to the rescue
        /// window. Low-certainty proposals are INCLUDED — they arrive red
        /// and queue for review on apply (the reply-2 guards) — but
        /// doNotTrack/unattributable evidence never proposes anything.
        package var proposals: [Proposal]
        /// Evidence-less (or unattributable) time inside the window — it
        /// stays exactly as tracked, on the pinned task.
        package var keptSeconds: TimeInterval

        package var isEmpty: Bool { proposals.isEmpty }
    }

    /// Merge gap: two attributed runs of the same target with less than
    /// this between them read as one continuous stretch (screen-reading,
    /// thinking) rather than two slices.
    package static let mergeGap: TimeInterval = 120

    /// Build the rebuilt-timeline proposal for [from, to].
    /// - evidence: journal spans overlapping the window; only rows marked
    ///   `observedWhileAway` count (the shadow track never bills — this is
    ///   its one consumer).
    /// - minSlice: proposals shorter than this are noise and stay pinned.
    /// - attribute: the engine at the span's own moment. Returning nil (or
    ///   a non-task target) leaves that evidence with the pinned task.
    /// `requireAwayMarked: false` is the END-TIME-ORPHAN mode (13 Aug
    /// reply 2's extension): the vacated stretch's evidence is ordinary
    /// recorded windows, not the away shadow track — same replay, same
    /// guards.
    package static func plan(evidence: [FocusSpan], from: Date, to: Date,
                            minSlice: TimeInterval = 60,
                            requireAwayMarked: Bool = true,
                            attribute: (ActivitySignal, Date) -> (target: Target, certainty: Double, provenance: SessionProvenance?)?)
        -> Plan {
        let window = evidence
            .filter { (!requireAwayMarked || $0.observedWhileAway)
                        && $0.end > from && $0.start < to }
            .sorted { $0.start < $1.start }
        var runs: [Proposal] = []
        for span in window {
            let start = max(span.start, from)
            let end = min(span.end, to)
            guard end > start else { continue }
            guard let verdict = attribute(span.signal, span.start),
                  case .task = verdict.target else { continue }
            if var last = runs.last, last.target == verdict.target,
               start.timeIntervalSince(last.end) <= mergeGap {
                last.end = end
                // The run keeps its strongest reading: certainty is the max
                // the engine reached anywhere inside it.
                if verdict.certainty > last.certainty {
                    last.certainty = verdict.certainty
                    last.provenance = verdict.provenance
                    last.app = span.signal.app
                }
                runs[runs.count - 1] = last
            } else {
                runs.append(Proposal(start: start, end: end,
                                     target: verdict.target,
                                     certainty: verdict.certainty,
                                     provenance: verdict.provenance,
                                     app: span.signal.app))
            }
        }
        // Sub-floor runs are noise and stay pinned; keptSeconds is simply
        // everything in the window the proposals don't cover (evidence-less
        // gaps, unattributable evidence and the dropped short runs alike).
        let proposals = runs.filter { $0.seconds >= minSlice }
        let coveredSeconds = proposals.reduce(0.0) { $0 + $1.seconds }
        let total = to.timeIntervalSince(from)
        return Plan(proposals: proposals,
                    keptSeconds: max(0, total - coveredSeconds))
    }

    /// The more-auto half of reply 2: whether ENDING an away stretch should
    /// offer the rescue unprompted. Material evidence only — a coffee
    /// walk-away with barely anything recorded must never nag; the
    /// forgot-the-toggle day (the case that costs real hours) always
    /// crosses this floor.
    package static let offerEvidenceFloor: TimeInterval = 300

    package static func shouldOffer(evidenceSeconds: TimeInterval) -> Bool {
        evidenceSeconds >= offerEvidenceFloor
    }
}

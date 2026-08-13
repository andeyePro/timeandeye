import Foundation

/// Fix 1 of the 2026-08-13 over-learning diagnosis: which surfaces a BULK
/// correction gesture may teach, and at what weight. A single, deliberate
/// gesture on one thing (one slice edited, one span filed, one review row
/// assigned) always teaches at full confirmation strength — the user
/// demonstrably meant that surface. But a bulk gesture (multi-session
/// timeline reassign, multi-surface review sweep, AI paste, walk-through
/// confirm) sweeps up flit windows the user never looked at, and teaching
/// each of those at full strength — plus priming them — is how "I
/// recategorised a block and now every window opened during it belongs to
/// that task" happened (Martin's #1-priority report, 13 Aug). Pure decision
/// logic so the Linux subset can pin it; AppController applies it.
package enum TeachScope {
    /// A session/surface inside a bulk gesture must carry at least this much
    /// duration to be something the user demonstrably meant.
    package static let bulkFloor: TimeInterval = 120
    /// Full confirmation weight is restored from this much covered time.
    package static let fullWeightDuration: TimeInterval = 300
    /// The confirmation teach weight (the correction operator's +2).
    package static let confirmWeight: Double = 2

    /// Whether one session inside a timeline reassign teaches its dominant
    /// surface. A single-session gesture always teaches (direct word); in a
    /// multi-session selection, sub-floor sessions are flits riding along.
    package static func bulkReassignTeaches(sessionDuration: TimeInterval,
                                            selectionCount: Int) -> Bool {
        selectionCount <= 1 || sessionDuration >= bulkFloor
    }

    /// The teach weight for one surface of a review-drawer assign, or nil to
    /// skip it entirely (no count teach, no prime). A single-surface assign
    /// is the user's direct word: full weight regardless of duration. In a
    /// multi-surface sweep, a surface below the floor is skipped, and one
    /// above it teaches at a weight scaled by its covered duration — full
    /// strength only from `fullWeightDuration` of evidence.
    package static func reviewTeachWeight(coveredDuration: TimeInterval,
                                          surfaceCount: Int) -> Double? {
        guard surfaceCount > 1 else { return confirmWeight }
        guard coveredDuration >= bulkFloor else { return nil }
        return confirmWeight * min(1, coveredDuration / fullWeightDuration)
    }
}

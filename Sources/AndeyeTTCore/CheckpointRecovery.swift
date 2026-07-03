import Foundation

/// Pure decision for what to do with a live-checkpoint row a crash/quit left
/// behind. Kept out of AppController so it is checkable: the controller's
/// `promoteStaleCheckpoint` is just I/O around this.
public enum CheckpointRecovery {
    /// Whether a stale checkpoint should be promoted to a real, pushable slice.
    ///
    /// Returns nil (drop the checkpoint, recover nothing) when:
    ///  - there is no stale row, or
    ///  - the stretch is shorter than `floor` (sub-floor time is noise), or
    ///  - the stretch is already covered by an already-journalled slice for the
    ///    SAME task — i.e. a task switch flushed the slice but the checkpoint
    ///    was not re-anchored, so promoting it would duplicate the time (and the
    ///    OP entry).
    /// Otherwise returns `stale` unchanged — genuine crash-lost time to recover.
    public static func recover(stale: Session?, floor: TimeInterval,
                               alreadyJournalled: [Session]) -> Session? {
        guard let stale else { return nil }
        guard stale.end.timeIntervalSince(stale.start) >= floor else { return nil }
        let covered = alreadyJournalled.contains { other in
            other.task == stale.task
                && other.start <= stale.start
                && other.end >= stale.end
        }
        return covered ? nil : stale
    }
}

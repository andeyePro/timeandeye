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
    ///  - after subtracting every same-task journalled overlap, less than
    ///    `floor` remains — a task switch flushed (part of) the slice, so
    ///    promoting the overlapped span would duplicate time + the OP entry.
    /// Otherwise returns the stale span TRIMMED to its largest un-journalled
    /// remainder (C18: a partial overlap used to promote the WHOLE span,
    /// double-counting the overlapped part; full containment is now just the
    /// remainder hitting zero).
    public static func recover(stale: Session?, floor: TimeInterval,
                               alreadyJournalled: [Session]) -> Session? {
        guard let stale else { return nil }
        guard stale.end.timeIntervalSince(stale.start) >= floor else { return nil }
        // Subtract same-task overlaps, keeping every remaining fragment.
        var fragments: [(start: Date, end: Date)] = [(stale.start, stale.end)]
        for other in alreadyJournalled where other.task == stale.task {
            var next: [(start: Date, end: Date)] = []
            for f in fragments {
                guard other.start < f.end, other.end > f.start else { next.append(f); continue }
                if f.start < other.start { next.append((f.start, other.start)) }
                if other.end < f.end { next.append((other.end, f.end)) }
            }
            fragments = next
        }
        // Recover the LARGEST remainder (one checkpoint row promotes one
        // slice; multiple disjoint remainders would need ids we don't have —
        // the big one is the real lost time, the slivers are switch noise).
        guard let best = fragments.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }), best.end.timeIntervalSince(best.start) >= floor else { return nil }
        var recovered = stale
        recovered.start = best.start
        recovered.end = best.end
        return recovered
    }
}

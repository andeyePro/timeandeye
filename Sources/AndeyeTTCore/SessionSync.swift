import Foundation

/// How a slice came to exist — the authority ladder for cross-device overlap
/// resolution: a deliberate timeline edit beats a manual (started-by-hand)
/// timer beats automatic tracking. Ascending rawValue = ascending authority.
public enum SliceOrigin: Int, Codable, Comparable, Sendable {
    case auto = 0      // sensor-attributed tracking
    case manual = 1    // user started/claimed this slice by hand (iOS tap, gap claim)
    case edited = 2    // user shaped it in the timeline editor

    public static func < (a: SliceOrigin, b: SliceOrigin) -> Bool { a.rawValue < b.rawValue }
}

/// One revision of a synced session: the record plus its merge metadata.
/// `deleted` is a tombstone — deletes must travel between devices, so a
/// deleted session keeps its row (and HLC) rather than vanishing.
public struct SessionRevision: Equatable, Codable, Sendable, Identifiable {
    public var session: Session
    public var hlc: HLC
    public var origin: SliceOrigin
    public var deleted: Bool

    public var id: UUID { session.id }

    public init(session: Session, hlc: HLC, origin: SliceOrigin = .auto,
                deleted: Bool = false) {
        self.session = session
        self.hlc = hlc
        self.origin = origin
        self.deleted = deleted
    }
}

/// Deterministic merge for the synced journal. Pure functions only: every
/// device holding the same set of revisions computes the identical journal,
/// regardless of the order the revisions arrived in.
public enum SessionMerge {

    // MARK: - Record level (last-writer-wins by HLC)

    /// The surviving revision for one record id. Newer HLC wins outright —
    /// including tombstones (a newer delete beats an edit; a newer edit
    /// resurrects a deleted record: the user re-instated it after deleting).
    /// INVARIANT: a revision's content is immutable for a given HLC — every
    /// local mutation re-stamps via tick(). Equal HLC therefore means equal
    /// content; the deleted-wins tiebreak is belt-and-braces so a violated
    /// invariant can still never diverge two replicas.
    public static func merge(local: SessionRevision?, remote: SessionRevision?) -> SessionRevision? {
        switch (local, remote) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
            if l.hlc != r.hlc { return l.hlc > r.hlc ? l : r }
            return l.deleted ? l : r.deleted ? r : l
        }
    }

    /// Merge two whole replicas by record id (order-independent). Output
    /// order is total (start, then id) so replicas compare as arrays.
    public static func merge(_ a: [SessionRevision], _ b: [SessionRevision]) -> [SessionRevision] {
        var byID: [UUID: SessionRevision] = [:]
        for rev in a { byID[rev.id] = merge(local: byID[rev.id], remote: rev) }
        for rev in b { byID[rev.id] = merge(local: byID[rev.id], remote: rev) }
        return byID.values.sorted {
            $0.session.start != $1.session.start
                ? $0.session.start < $1.session.start
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    // MARK: - Set level (overlap resolution)

    /// Priority for the overlap walk: higher authority first, then newer,
    /// then id as the final total-order tiebreak. A pure function of the set,
    /// so every device walks in the same order.
    static func priority(_ a: SessionRevision, _ b: SessionRevision) -> Bool {
        if a.origin != b.origin { return a.origin > b.origin }
        if a.hlc != b.hlc { return a.hlc > b.hlc }
        return a.id.uuidString < b.id.uuidString
    }

    /// Resolve time-overlaps among the LIVE (non-deleted) revisions: walk in
    /// priority order; each session keeps only time not already claimed by a
    /// higher-priority one. Trims never invent time; a fully-covered session
    /// comes back marked deleted. A middle overlap keeps the LOSER's larger
    /// remaining side (no nondeterministic splits in v1; ties prefer the
    /// earlier side). Deleted revisions pass through untouched.
    ///
    /// This is a DERIVED VIEW, not a mutation of the synced truth: the raw
    /// revisions are what replicas exchange (their HLCs unchanged here), and
    /// every device derives the identical normalised journal from the same
    /// raw set. Persisting or pushing the derived trims would let two devices
    /// hold different content under one HLC — the one way LWW can diverge.
    /// The UI, aggregation and the backend pusher all read this view.
    public static func resolveOverlaps(_ revisions: [SessionRevision]) -> [SessionRevision] {
        let live = revisions.filter { !$0.deleted }.sorted(by: priority)
        let dead = revisions.filter { $0.deleted }
        var claimed: [(start: Date, end: Date)] = []
        var out: [SessionRevision] = []
        for var rev in live {
            var start = rev.session.start
            var end = rev.session.end
            // Subtract each claimed interval; on a middle-split keep the
            // larger side (earlier side on a tie).
            var covered = false
            for c in claimed {
                guard c.start < end, c.end > start else { continue }   // no overlap
                if c.start <= start, c.end >= end { covered = true; break }
                if c.start <= start {
                    start = max(start, c.end)          // trim front
                } else if c.end >= end {
                    end = min(end, c.start)            // trim back
                } else {
                    // Winner strictly inside: keep the larger remaining side.
                    let front = c.start.timeIntervalSince(start)
                    let back = end.timeIntervalSince(c.end)
                    if front >= back { end = c.start } else { start = c.end }
                }
                if start >= end { covered = true; break }
            }
            if covered {
                rev.deleted = true
                out.append(rev)
                continue
            }
            rev.session.start = start
            rev.session.end = end
            claimed.append((start, end))
            out.append(rev)
        }
        return (out + dead).sorted {
            $0.session.start != $1.session.start
                ? $0.session.start < $1.session.start
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The full pipeline: record-merge two replicas, then normalise overlaps.
    public static func converge(_ a: [SessionRevision], _ b: [SessionRevision]) -> [SessionRevision] {
        resolveOverlaps(merge(a, b))
    }
}

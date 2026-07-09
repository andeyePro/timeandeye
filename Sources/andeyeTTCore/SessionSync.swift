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
    /// higher-priority one. Trims never invent time AND never destroy it: a
    /// claim punched through the middle of a longer session splits it, and
    /// EVERY remaining fragment survives — the first under the parent's id,
    /// the rest under DETERMINISTIC child ids (`fragmentID`), so all replicas
    /// still derive the identical view. (The old rule kept only the larger
    /// side: a 5-minute manual slice claimed inside a 3-hour auto session
    /// silently discarded the shorter remainder — tracked time destroyed
    /// from display, aggregation and posting. Fable F23.) A fully-covered
    /// session comes back marked deleted. Deleted revisions pass through
    /// untouched.
    ///
    /// This is a DERIVED VIEW, not a mutation of the synced truth: the raw
    /// revisions are what replicas exchange (their HLCs unchanged here), and
    /// every device derives the identical normalised journal from the same
    /// raw set. Persisting or pushing the derived trims would let two devices
    /// hold different content under one HLC — the one way LWW can diverge.
    /// The UI, aggregation and the backend pusher all read this view.
    public static func resolveOverlaps(_ revisions: [SessionRevision]) -> [SessionRevision] {
        resolve(revisions).view
    }

    /// Per-PARENT surviving time in the resolved view: session id → (earliest
    /// surviving start, summed surviving seconds). Fragments fold back into
    /// their parent, so the POSTING layer can bill one backend entry per
    /// stored session at its resolved size without ever keying ledger rows by
    /// derived fragment ids. A fully-covered session simply has no entry.
    public static func resolvedContributions(
        _ revisions: [SessionRevision]) -> [UUID: (start: Date, seconds: TimeInterval)] {
        let (view, parentOf) = resolve(revisions)
        var out: [UUID: (start: Date, seconds: TimeInterval)] = [:]
        for rev in view where !rev.deleted {
            let parent = parentOf[rev.id] ?? rev.id
            let seconds = rev.session.end.timeIntervalSince(rev.session.start)
            if let existing = out[parent] {
                out[parent] = (min(existing.start, rev.session.start),
                               existing.seconds + seconds)
            } else {
                out[parent] = (rev.session.start, seconds)
            }
        }
        return out
    }

    /// The shared walk: the resolved view plus fragment→parent linkage (only
    /// EXTRA fragments appear in `parentOf`; a parent's first surviving
    /// fragment keeps its own id).
    static func resolve(_ revisions: [SessionRevision])
        -> (view: [SessionRevision], parentOf: [UUID: UUID]) {
        let live = revisions.filter { !$0.deleted }.sorted(by: priority)
        let dead = revisions.filter { $0.deleted }
        var claimed: [(start: Date, end: Date)] = []
        var parentOf: [UUID: UUID] = [:]
        var out: [SessionRevision] = []
        for rev in live {
            // Subtract every claimed interval: the remainder is 0..N
            // fragments, in ascending time order.
            var fragments: [(start: Date, end: Date)] = [(rev.session.start, rev.session.end)]
            for c in claimed {
                var next: [(start: Date, end: Date)] = []
                for f in fragments {
                    guard c.start < f.end, c.end > f.start else { next.append(f); continue }
                    if f.start < c.start { next.append((f.start, c.start)) }
                    if c.end < f.end { next.append((c.end, f.end)) }
                }
                fragments = next
            }
            guard !fragments.isEmpty else {
                var covered = rev
                covered.deleted = true
                out.append(covered)
                continue
            }
            for (k, f) in fragments.enumerated() {
                var piece = rev
                piece.session.start = f.start
                piece.session.end = f.end
                if k > 0 {
                    piece.session.id = Self.fragmentID(parent: rev.id, index: k)
                    parentOf[piece.session.id] = rev.id
                }
                claimed.append(f)
                out.append(piece)
            }
        }
        let view = (out + dead).sorted {
            $0.session.start != $1.session.start
                ? $0.session.start < $1.session.start
                : $0.id.uuidString < $1.id.uuidString
        }
        return (view, parentOf)
    }

    /// Deterministic id for the k-th EXTRA fragment (k ≥ 1) of a split
    /// parent: a pure function of (parent id, k), so every replica walking
    /// the same raw set mints the IDENTICAL child ids — the property that
    /// keeps the derived view replica-identical without persisting or
    /// syncing the fragments. Two independent 64-bit FNV-1a streams fill the
    /// UUID; the RFC 4122 version nibble is pinned to 8 (a "custom" UUID)
    /// so derived ids live in a different namespace from random v4 session
    /// ids and can never collide with one.
    public static func fragmentID(parent: UUID, index: Int) -> UUID {
        var input = [UInt8]()
        withUnsafeBytes(of: parent.uuid) { input.append(contentsOf: $0) }
        input.append(contentsOf: Array("tail-\(index)".utf8))
        func fnv1a(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in input {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01B3   // FNV-1a 64-bit prime
            }
            return h
        }
        let hi = fnv1a(0xcbf2_9ce4_8422_2325)    // FNV offset basis
        let lo = fnv1a(0x9e37_79b9_7f4a_7c15)    // independent second stream
        var u = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { raw in
            raw.storeBytes(of: hi.bigEndian, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: lo.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        u.6 = (u.6 & 0x0F) | 0x80   // version 8 (custom, per RFC 9562)
        u.8 = (u.8 & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: u)
    }

    /// True for a `fragmentID`-derived id (overlap-view fragments, and
    /// JournalPrune's consolidation rollups) — the version-8 "custom" nibble
    /// `fragmentID` stamps in is a namespace a real session's random v4 id
    /// can never occupy. Lets a prune step tell rollups from raw slices
    /// without a stored flag.
    public static func isDerivedID(_ id: UUID) -> Bool {
        id.uuid.6 & 0xF0 == 0x80
    }

    /// The full pipeline: record-merge two replicas, then normalise overlaps.
    public static func converge(_ a: [SessionRevision], _ b: [SessionRevision]) -> [SessionRevision] {
        resolveOverlaps(merge(a, b))
    }
}

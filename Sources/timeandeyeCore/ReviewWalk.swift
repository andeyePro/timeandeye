import Foundation

// Walk-through review (Martin's respec, 2026-07-11, "I'm not sure
// I like one click confirms the whole day … Why not something that lets me
// scroll through from left to right or right to left, dig in as much as I
// like then one click confirms I am happy with the slices I have viewed?").
// There is deliberately NO whole-day confirm anywhere: one click covers
// exactly the slices the user has actually visited, so confirming part of
// the day and coming back later just works.

/// The walk's state: the day's pending slices in chronological order (left =
/// earlier, right = later), which one the cursor is on, and which the user
/// has VIEWED — visited by arrow, clicked, or opened. Pure value semantics
/// so the CLT-only loop can check it; the drawer renders membership and the
/// controller owns one instance for the app run (viewed marks survive
/// closing and reopening the window; a relaunch starts a fresh walk — the
/// simple honest option: nothing is journalled about mere attention).
package struct ReviewWalk: Equatable, Sendable {
    /// Arrow vocabulary: on a chronological day strip, left is earlier.
    package enum Direction: Sendable {
        case left
        case right
    }

    /// The pending slice ids, earliest first — set by `update` on every
    /// queue reload, never mutated elsewhere.
    package private(set) var order: [UUID] = []
    /// Every slice the user has visited and that is STILL pending — what
    /// one confirm click covers. Slices acted on meanwhile (assigned,
    /// refiled, cleared, retro-accepted) are handled, not merely viewed,
    /// so `update` drops them.
    package private(set) var viewed: Set<UUID> = []
    /// Where the walk is — highlighted in the drawer; nil before the first
    /// step/click and after the queue empties around it.
    package private(set) var current: UUID?

    package init() {}

    package var viewedCount: Int { viewed.count }

    /// The queue changed (assign, refile, clear, retro pass, reload):
    /// handled slices leave `viewed`, and a cursor whose slice was handled
    /// relocates to the nearest survivor — rightward first, so "assign and
    /// walk on" keeps moving through the day — else leftward, else nil.
    /// Relocation is mechanical, NOT a view: the user hasn't looked at the
    /// slice the cursor lands on, so it is never marked viewed here.
    package mutating func update(order newOrder: [UUID]) {
        let survivors = Set(newOrder)
        viewed.formIntersection(survivors)
        if let cur = current, !survivors.contains(cur) {
            var relocated: UUID?
            if let oi = order.firstIndex(of: cur) {
                relocated = order[(oi + 1)...].first(where: survivors.contains)
                    ?? order[..<oi].reversed().first(where: survivors.contains)
            }
            current = relocated
        }
        order = newOrder
    }

    /// Arrow step: move the cursor one slice earlier (←) or later (→). No
    /// cursor yet: → enters the day at the earliest slice, ← at the latest —
    /// walking right-to-left is first-class, not a reverse gear. At either
    /// end the cursor stays put (the day has edges; no wrap). Landing IS a
    /// visit: the slice joins the viewed set.
    package mutating func step(_ direction: Direction) {
        guard !order.isEmpty else { return }
        let landed: UUID
        if let cur = current, let i = order.firstIndex(of: cur) {
            if !viewed.contains(cur) {
                // A relocated cursor (see `update`) sits on a slice nobody
                // has looked at. An arrow must never skip past it unviewed:
                // the first press opens what the cursor shows, in place;
                // the next press walks on.
                landed = cur
            } else {
                switch direction {
                case .right: landed = i + 1 < order.count ? order[i + 1] : cur
                case .left: landed = i > 0 ? order[i - 1] : cur
                }
            }
        } else {
            landed = direction == .right ? order[0] : order[order.count - 1]
        }
        visit(landed)
    }

    /// Explicit attention on one slice — an arrow landing, a click on the
    /// slice's row, or opening its detail disclosure. Digging in deeper
    /// (expanding, reassigning siblings, walking away and back) never
    /// unmarks it: `viewed` only ever shrinks via `update`, when a slice
    /// stops being pending. Ids not in the current order are ignored — a
    /// stale click can't mark a phantom viewed.
    package mutating func visit(_ id: UUID) {
        guard order.contains(id) else { return }
        current = id
        viewed.insert(id)
    }
}

/// What ONE confirm click does: the viewed, still-pending slices each take
/// the engine's CURRENT best read — the same explain numbers the user just
/// saw in each slice's detail — as the user's word. Pure planning only (the
/// shape `RetroAcceptance` set): the caller applies the plan through the
/// journal and its own assign path, grouped into one undo step.
package enum ReviewConfirm {
    /// One target's share of the confirm: its slices (queue order) and the
    /// overlapping sessions to stamp as user-decided (prior state captured
    /// for the undo closure — `RetroDigest.PriorSessionState` is exactly
    /// that payload already).
    package struct Assignment: Equatable, Sendable {
        package var target: Target
        package var segmentIDs: [UUID]
        package var sessionStamps: [RetroDigest.PriorSessionState]

        package init(target: Target, segmentIDs: [UUID],
                    sessionStamps: [RetroDigest.PriorSessionState] = []) {
            self.target = target
            self.segmentIDs = segmentIDs
            self.sessionStamps = sessionStamps
        }
    }

    package struct Plan: Equatable, Sendable {
        /// Per-target batches, targets in first-seen queue order.
        package var assignments: [Assignment]
        /// Viewed slices the scorer has NO answer for (nothing matched yet):
        /// there is no word to give, so they stay queued untouched — confirm
        /// never invents a target.
        package var unresolved: [UUID]

        package init(assignments: [Assignment] = [], unresolved: [UUID] = []) {
            self.assignments = assignments
            self.unresolved = unresolved
        }

        package var confirmedCount: Int {
            assignments.reduce(0) { $0 + $1.segmentIDs.count }
        }
    }

    /// What a confirmed slice's session carries afterwards. `userAssigned`
    /// — the EXISTING user's-word state, not a parallel one — so the
    /// contradiction pass (`ContradictionRefile.userDecided`) never refiles
    /// or nags it, and the retro lift's below-bar gate never touches it
    /// again; the detail names the gesture for the Evidence Card.
    package static let stampProvenance = SessionProvenance(
        sourceRaw: "userAssigned", detail: "confirmed in review")

    /// Plan a confirm of `viewed` against the CURRENT queue. Only ids still
    /// in `pending` count (a slice handled since it was viewed is already
    /// decided); everything unviewed is untouched by construction — it never
    /// enters the plan. `score` re-derives each slice's best answer at its
    /// own moment (the retro pass's own closure shape, reused so a confirm
    /// can never disagree with the numbers the detail disclosure showed).
    ///
    /// Session stamps use the retro-lift/Unknown-sweep gate — unpushed,
    /// still below `bar`, overlapping the confirmed slice — so a confirm
    /// never re-points posted time or an already-confident session. Each
    /// session is claimed at most once (first confirmed slice in queue
    /// order wins); `.doNotTrack` reads clear the slice but stamp nothing
    /// (there is no task a session could carry).
    package static func plan(viewed: Set<UUID>, pending: [ReviewSegment],
                            sessions: [Session], bar: Double,
                            score: (ActivitySignal) -> (target: Target, score: Double)?) -> Plan {
        var targetOrder: [Target] = []
        var idsByTarget: [Target: [UUID]] = [:]
        var segmentsByTarget: [Target: [ReviewSegment]] = [:]
        var unresolved: [UUID] = []
        for segment in pending where viewed.contains(segment.id) {
            guard let result = score(segment.signal) else {
                unresolved.append(segment.id)
                continue
            }
            if idsByTarget[result.target] == nil { targetOrder.append(result.target) }
            idsByTarget[result.target, default: []].append(segment.id)
            segmentsByTarget[result.target, default: []].append(segment)
        }
        var claimed = Set<UUID>()
        let assignments: [Assignment] = targetOrder.map { target in
            var stamps: [RetroDigest.PriorSessionState] = []
            if case .task = target {
                let segments = segmentsByTarget[target] ?? []
                for session in sessions
                where !claimed.contains(session.id)
                    && RetroEligibility.eligible(session, below: bar, anyOf: segments) {
                    claimed.insert(session.id)
                    stamps.append(RetroDigest.PriorSessionState(
                        id: session.id, task: session.task,
                        certainty: session.certainty,
                        priorProvenance: session.provenance))
                }
            }
            return Assignment(target: target, segmentIDs: idsByTarget[target] ?? [],
                              sessionStamps: stamps)
        }
        return Plan(assignments: assignments, unresolved: unresolved)
    }
}

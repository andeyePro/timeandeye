import Foundation
import andeyeTTCore

// MARK: - ReviewStack (approvals-drawer spec — stack-by-default drawer shape)

func reviewStackChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
            title: String? = nil, url: String? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title, tabURL: url,
                     start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    c.check("groups identical app|windowTitle|tabURL into one stack, preserving queue order within it") {
        let a1 = seg("Chrome", 0, 60, title: "Insurance")
        let b1 = seg("Ghostty", 100, 160, title: "andeyeTT")
        let a2 = seg("Chrome", 200, 260, title: "Insurance")
        let stacks = [a1, b1, a2].stacked()
        try expectEq(stacks.count, 2, "two distinct surfaces")
        let chromeStack = try unwrap(stacks.first { $0.app == "Chrome" })
        try expectEq(chromeStack.segments.map(\.id), [a1.id, a2.id],
                     "queue order within the stack, not reordered")
    }

    c.check("newest stack first, ordered by each stack's most recent segment") {
        let older = seg("A", 0, 60)          // ends earliest
        let newer = seg("B", 500, 560)       // ends latest
        let middle = seg("C", 200, 260)
        let stacks = [older, newer, middle].stacked()
        try expectEq(stacks.map(\.app), ["B", "C", "A"])
    }

    c.check("total sums segment durations; first/last span the whole group") {
        let a = seg("Chrome", 0, 60, title: "X")          // 60s
        let b = seg("Chrome", 100, 250, title: "X")       // 150s
        let stacks = [a, b].stacked()
        let stack = try unwrap(stacks.first)
        try expectEq(stack.total, 210)
        try expectEq(stack.first, t0)
        try expectEq(stack.last, t0.addingTimeInterval(250))
    }

    c.check("distinct windowTitle/tabURL on the same app never collapse together") {
        let a = seg("Chrome", 0, 60, title: "Tab A")
        let b = seg("Chrome", 60, 120, title: "Tab B")
        try expectEq([a, b].stacked().count, 2)
    }

    c.check("stacking and the floor pass segments through WHOLE — per-slice email evidence intact") {
        // The grain footer reads evidence off the segments a stack hands it,
        // and the floor runs on every reload — if either path rebuilt rows
        // from just the surface fields, the evidence would silently vanish
        // between queue time and the footer's offer.
        var a = seg("Mail", 0, 70, title: "Inbox")
        a.correspondents = ["amy@x.co"]
        a.emailSubject = "Renewal"
        var b = seg("Mail", 100, 170, title: "Inbox")
        b.correspondents = ["bob@y.co"]
        let stack = try unwrap([a, b].stacked().first)
        try expectEq(stack.segments, [a, b],
                     "the stack holds the exact segments — differing per-slice evidence untouched")
        try expectEq([a, b].meetingReviewFloor(60), [a, b],
                     "the floor filters (each 70s segment >= 60s), never rewrites")
    }
}

// MARK: - Review sort + range select (2026-07-09, Martin clearing a backlog:
// "sort by fields at the top: time, duration, and the ability … to select
// (at least with shift click start and end of selection) so they can get rid
// of everything underneath whatever duration or before whatever date").
// The sort comparators and the range's index math are pure so this CLT-only
// loop can check them; the drawer just displays `sorted(by:)`'s order and
// lets AppKit's extended selection pick ranges over it.

func reviewSortAndRangeChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
             title: String? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title,
                      start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    // Three stacks with deliberately CROSSED rankings so no two orders can
    // accidentally agree: A ends latest but is shortest; C ends earliest
    // but is longest; B sits between on both axes.
    // A: 500–560 (60s, newest), B: 200–320 (120s), C: 0–180 (180s, oldest).
    let stacks = [seg("A", 500, 560), seg("B", 200, 320), seg("C", 0, 180)].stacked()

    c.check("newestFirst matches the drawer's historical default (last activity, descending)") {
        try expectEq(stacks.sorted(by: .newestFirst).map(\.app), ["A", "B", "C"])
    }

    c.check("oldestFirst is the sweep-before-a-date order (last activity, ascending)") {
        try expectEq(stacks.sorted(by: .oldestFirst).map(\.app), ["C", "B", "A"])
    }

    c.check("longest/shortest order by the stack's TOTAL, not its recency") {
        try expectEq(stacks.sorted(by: .longestFirst).map(\.app), ["C", "B", "A"])
        try expectEq(stacks.sorted(by: .shortestFirst).map(\.app), ["A", "B", "C"])
    }

    c.check("time orders key on LAST activity — a recently-active old-starter is not 'old'") {
        // The sweep guarantee: with oldestFirst, every stack ABOVE the
        // cutoff row is entirely before it. A surface first touched at t0
        // but touched again at 900 must rank NEWER than one wholly at
        // 300–360; keying on `first` would invert that and let a sweep
        // "before 400" swallow it.
        let longLived = [seg("Old starter", 0, 60, title: "x"),
                         seg("Old starter", 840, 900, title: "x")]
        let wholly = [seg("Wholly old", 300, 360)]
        let both = (longLived + wholly).stacked().sorted(by: .oldestFirst)
        try expectEq(both.map(\.app), ["Wholly old", "Old starter"])
    }

    c.check("a duration tie breaks by recency then id — equal rows never shuffle on reload") {
        let tied = [seg("Same1", 0, 60), seg("Same2", 100, 160), seg("Twin2", 100, 160)].stacked()
        try expectEq(tied.sorted(by: .longestFirst).map(\.app), ["Same2", "Twin2", "Same1"],
                     "all 60s totals: newest first, then id for the exact twins")
        try expectEq(tied.sorted(by: .shortestFirst).map(\.app), ["Same2", "Twin2", "Same1"],
                     "same tie-break both directions — flipping the sort never reverses ties")
    }

    c.check("range endpoints are inclusive, in either direction") {
        let ids = ["a", "b", "c", "d", "e"]
        try expectEq(ReviewRangeSelect.range(in: ids, from: "b", to: "d"), ["b", "c", "d"])
        try expectEq(ReviewRangeSelect.range(in: ids, from: "d", to: "b"), ["b", "c", "d"],
                     "shift-click above the anchor selects the same range")
    }

    c.check("anchor == target selects exactly that one row") {
        try expectEq(ReviewRangeSelect.range(in: ["a", "b"], from: "a", to: "a"), ["a"])
    }

    c.check("no anchor (or a vanished one) degrades to the clicked row; a vanished target selects nothing") {
        // The anchor row can be assigned away between clicks — degrading to
        // the target is the only non-guess.
        let ids = ["a", "b", "c"]
        try expectEq(ReviewRangeSelect.range(in: ids, from: nil, to: "b"), ["b"])
        try expectEq(ReviewRangeSelect.range(in: ids, from: "gone", to: "b"), ["b"])
        try expectEq(ReviewRangeSelect.range(in: ids, from: "a", to: "gone"), [])
    }

    c.check("the range follows the CURRENT sort order — same endpoints, different members") {
        // Martin's two sweeps use the same gesture over different orders:
        // oldest-first + range-from-top clears before-a-date; shortest-
        // first + range-from-top clears below-a-duration.
        let byOldest = stacks.sorted(by: .oldestFirst).map(\.id)
        let byShortest = stacks.sorted(by: .shortestFirst).map(\.id)
        let cID = try unwrap(stacks.first { $0.app == "C" }).id
        let aID = try unwrap(stacks.first { $0.app == "A" }).id
        let bID = try unwrap(stacks.first { $0.app == "B" }).id
        try expectEq(ReviewRangeSelect.range(in: byOldest, from: byOldest[0], to: bID),
                     [cID, bID], "oldest-first: C then B — everything before B's date")
        try expectEq(ReviewRangeSelect.range(in: byShortest, from: byShortest[0], to: bID),
                     [aID, bID], "shortest-first: A then B — everything at/below B's duration")
    }

    c.check("an id-keyed selection resolves to the same stacks after a re-sort") {
        // The drawer keeps the selection Set across a sort change (it means
        // "these surfaces", not "these positions") — valid only because
        // sorting never rewrites ids or stack contents.
        let picked = Set(stacks.sorted(by: .oldestFirst).prefix(2).map(\.id))
        let before = stacks.sorted(by: .oldestFirst).filter { picked.contains($0.id) }
        let after = stacks.sorted(by: .longestFirst).filter { picked.contains($0.id) }
        try expectEq(Set(before.map(\.app)), Set(after.map(\.app)))
        try expectEq(before.flatMap(\.segments).map(\.id).sorted { $0.uuidString < $1.uuidString },
                     after.flatMap(\.segments).map(\.id).sorted { $0.uuidString < $1.uuidString },
                     "the same underlying segments would be assigned either way")
    }

    c.check("sorting is a view-order concern only — stacks pass through whole") {
        for order in ReviewSortOrder.allCases {
            let sorted = stacks.sorted(by: order)
            try expectEq(Set(sorted.map(\.id)), Set(stacks.map(\.id)),
                         "\(order.rawValue) never drops or invents a stack")
            for s in sorted {
                let original = try unwrap(stacks.first { $0.id == s.id })
                try expectEq(s, original, "\(order.rawValue) never rewrites a stack")
            }
        }
    }
}

// MARK: - RetroAcceptance.plan (approvals-drawer spec §3)

func retroAcceptanceChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let bar = 0.8

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval) -> ReviewSegment {
        ReviewSegment(app: app, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    func session(_ certainty: Double, task: TaskRef = .op(1),
                _ start: TimeInterval, _ end: TimeInterval) -> Session {
        Session(task: task, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
               certainty: certainty)
    }

    c.check("clears only segments scoring at or above the bar; borderline stays queued") {
        let cleared = seg("Chrome", 0, 60)
        let borderline = seg("Slack", 100, 160)
        let untouched = seg("Mail", 200, 260)
        let scores: [String: Double] = ["Chrome": 0.9, "Slack": bar - 0.01, "Mail": 0.2]
        let plan = RetroAcceptance.plan(pending: [cleared, borderline, untouched], sessions: [], bar: bar) {
            signal in (target: .task(.op(1)), score: scores[signal.app] ?? 0)
        }
        try expectEq(plan.clearances.map(\.segmentID), [cleared.id],
                     "only the >= bar segment clears; the bar-ε segment and the low one stay")
    }

    c.check("lift never lowers certainty, and re-points the session's task") {
        let segment = seg("Chrome", 0, 600)
        // Overlaps the segment, certainty (0.5) below the bar.
        let low = session(0.5, task: .op(9), 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [low], bar: bar) { _ in
            (target: .task(.op(1)), score: 0.95)
        }
        try expectEq(plan.clearances.map(\.target), [.task(.op(1))])
        let lift = try unwrap(plan.lifts.first)
        try expectEq(lift.sessionID, low.id)
        try expectEq(lift.priorTask, .op(9))
        try expectEq(lift.priorCertainty, 0.5)
        try expectEq(lift.newTask, .op(1))
        try expectEq(lift.newCertainty, 0.95, "never lowers — raised to the new score")
    }

    c.check("a session already at/above the bar is untouched (only below-bar sessions lift)") {
        let segment = seg("Chrome", 0, 600)
        let confident = session(0.9, 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [confident], bar: bar) { _ in
            (target: .task(.op(2)), score: 0.95)
        }
        try expect(plan.lifts.isEmpty, "already-confident sessions are not retro-lift candidates")
    }

    c.check("a .doNotTrack clearance clears the row but lifts no session (a Session has no doNotTrack)") {
        let segment = seg("Chrome", 0, 600)
        let low = session(0.5, 0, 600)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [low], bar: bar) { _ in
            (target: .doNotTrack, score: 0.95)
        }
        try expectEq(plan.clearances.map(\.target), [.doNotTrack])
        try expect(plan.lifts.isEmpty)
    }

    c.check("a non-overlapping session never lifts") {
        let segment = seg("Chrome", 0, 60)
        let elsewhere = session(0.4, 1_000, 1_060)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [elsewhere], bar: bar) { _ in
            (target: .task(.op(1)), score: 0.95)
        }
        try expect(plan.lifts.isEmpty)
    }

    c.check("a session overlapping two cleared segments keeps the higher-scoring lift") {
        let first = seg("Chrome", 0, 100)
        let second = seg("Chrome", 50, 200)
        let spanning = session(0.3, 0, 200)   // overlaps both
        let scores: [TimeInterval: Double] = [0: 0.85, 50: 0.99]
        let plan = RetroAcceptance.plan(pending: [first, second], sessions: [spanning], bar: bar) { signal in
            let offset = signal.timestamp.timeIntervalSince(t0)
            return (target: .task(.op(1)), score: scores[offset] ?? 0)
        }
        try expectEq(plan.lifts.count, 1)
        try expectEq(plan.lifts.first?.newCertainty, 0.99)
    }

    c.check("no clearances -> an empty plan (nothing scores at/above the bar)") {
        let segment = seg("Chrome", 0, 60)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [], bar: bar) { _ in nil }
        try expect(plan.clearances.isEmpty && plan.lifts.isEmpty)
    }

    // MARK: - Unknown task category (2026-07-09), §3 retro reclaim

    c.check("an Unknown-assigned segment that now scores confidently reclaims to the real target") {
        // RetroAcceptance.plan is agnostic to where a segment came from —
        // "feed it pending + unknown-assigned segments together" (spec) just
        // means an already-assigned-to-Unknown segment scores exactly like a
        // still-pending one, and its clearance re-points it to whatever the
        // NEW confident target is (never back to Unknown).
        var unknownAssigned = seg("Chrome", 0, 600)
        unknownAssigned.assigned = .task(WorkTask.unknown.ref)
        let plan = RetroAcceptance.plan(pending: [unknownAssigned], sessions: [], bar: bar) { _ in
            (target: .task(.op(5)), score: 0.95)
        }
        try expectEq(plan.clearances.map(\.target), [.task(.op(5))],
                     "reclaims to the real target, not Unknown")
    }
}

// MARK: - Spec §8 acceptance shapes 1–2, purely (no Attributor/AppController —
// the mechanics AppController's applyRetroPlan/undoRetroDigest perform,
// exercised directly against a JournalStore).

func approvalsDrawerAcceptanceChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let bar = 0.8

    c.check("§8.1: a queued span clears on a retro pass, writes a digest, and undo loses nothing") {
        let journal = InMemoryJournalStore()
        let segment = ReviewSegment(app: "Chrome", windowTitle: "Insurance renewal",
                                    start: t0, end: t0.addingTimeInterval(300))
        try journal.save(segment)
        try expectEq(try journal.pendingReview().count, 1)

        // The retro pass: score >= bar (a pin just taught this surface).
        let plan = RetroAcceptance.plan(pending: try journal.pendingReview(), sessions: [], bar: bar) { _ in
            (target: .task(.op(42)), score: 0.9)
        }
        try expect(!plan.clearances.isEmpty)
        try journal.assign(plan.clearances.map(\.segmentID), to: .task(.op(42)))
        let digest = RetroDigest(clearedSegmentIDs: plan.clearances.map(\.segmentID),
                                 target: .task(.op(42)), count: plan.clearances.count,
                                 reason: "confidence rose", priorSessions: [])
        try journal.saveRetroDigest(digest)
        try expectEq(try journal.pendingReview().count, 0, "cleared")
        try expectEq(try journal.retroDigests(limit: 10).map(\.id), [digest.id], "one receipt")

        // Undo: nothing lost.
        try journal.assign(digest.clearedSegmentIDs, to: nil)
        try journal.deleteRetroDigest(digest.id)
        try expectEq(try journal.pendingReview().map(\.id), [segment.id], "the row comes back")
        try expectEq(try journal.retroDigests(limit: 10).count, 0)
    }

    c.check("§8.2: retro-clearing lifts the overlapping session's certainty into push eligibility") {
        let journal = InMemoryJournalStore()
        let segment = ReviewSegment(app: "Chrome", start: t0, end: t0.addingTimeInterval(600))
        let lowSession = Session(task: .op(7), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 0.5)
        try journal.save(segment)
        try journal.save(lowSession)
        try expectEq(try journal.sessions(needingPushAtOrAbove: bar), [],
                     "below the push bar before the retro pass")

        let plan = RetroAcceptance.plan(pending: [segment], sessions: [lowSession], bar: bar) { _ in
            (target: .task(.op(7)), score: 0.85)
        }
        let lift = try unwrap(plan.lifts.first)
        var lifted = try unwrap(try journal.session(id: lift.sessionID))
        lifted.task = lift.newTask
        lifted.certainty = lift.newCertainty
        try journal.update(lifted)

        try expectEq(try journal.sessions(needingPushAtOrAbove: bar).map(\.id), [lowSession.id],
                     "the lift makes the session push-eligible through the NORMAL sync path")
    }
}

// MARK: - Unknown task category (2026-07-09) — pure planning + guards

func unknownSweepChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let bar = 0.8
    let unknownRef = WorkTask.unknown.ref

    func seg(_ start: TimeInterval, _ end: TimeInterval) -> ReviewSegment {
        ReviewSegment(app: "Chrome", start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }
    func session(_ certainty: Double, _ start: TimeInterval, _ end: TimeInterval,
                pushed: Bool = false, task: TaskRef = .op(1)) -> Session {
        Session(task: task, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
               certainty: certainty, pushedToOP: pushed)
    }

    c.check("repoints an overlapping unpushed low-certainty session, unchanged certainty (no lift)") {
        let segment = seg(0, 600)
        let low = session(0.4, 0, 600)
        let repoints = UnknownSweep.sessionsToRepoint(segments: [segment], sessions: [low], bar: bar)
        try expectEq(repoints.map(\.sessionID), [low.id])
        try expectEq(repoints.first?.priorTask, .op(1))
    }

    c.check("a pushed session is never repointed") {
        let segment = seg(0, 600)
        let pushed = session(0.4, 0, 600, pushed: true)
        try expect(UnknownSweep.sessionsToRepoint(segments: [segment], sessions: [pushed], bar: bar).isEmpty)
    }

    c.check("a session already at/above the bar is never repointed") {
        let segment = seg(0, 600)
        let confident = session(0.9, 0, 600)
        try expect(UnknownSweep.sessionsToRepoint(segments: [segment], sessions: [confident], bar: bar)
            .isEmpty)
    }

    c.check("a non-overlapping session is never repointed") {
        let segment = seg(0, 60)
        let elsewhere = session(0.4, 1_000, 1_060)
        try expect(UnknownSweep.sessionsToRepoint(segments: [segment], sessions: [elsewhere], bar: bar)
            .isEmpty)
    }

    c.check("sweeping to Unknown never teaches the attributor; every other target does") {
        try expect(!Target.task(unknownRef).teachesAttributor,
                   "explicit don't-know, not a correction")
        try expect(Target.task(.op(1)).teachesAttributor)
        try expect(Target.doNotTrack.teachesAttributor)
    }
}

// MARK: - Review-queue admission floor (2026-07-09) — sub-minute slices stay
// off the queue. Martin: "There is extremely little value in having a user
// spend time categorising a <1m slice", and — overturning the same-day
// per-surface pooling — a visit shorter than the switch grace never becomes
// a tracked switch, so brief glances must not pool into a queue row "even
// if we visited it 1,000,000 times": the floor is per-SEGMENT. Contiguous
// same-surface time is already one segment when it reaches the queue
// (queueReview extends the pending segment), so only NON-contiguous brief
// glances vanish. Pure logic — the same `meetingReviewFloor` runs at
// reloadReview (the visible queue) and at the retro pass's unknownAssigned
// re-add, so these checks cover both paths.

func reviewFloorChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let floor: TimeInterval = 60

    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
             title: String? = nil, assigned: Target? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title, start: t0.addingTimeInterval(start),
                      end: t0.addingTimeInterval(end), assigned: assigned)
    }

    c.check("an isolated 30s segment is dropped — a lone <1m slice never becomes a review row") {
        try expect(([seg("Mail", 0, 30)]).meetingReviewFloor(floor).isEmpty)
    }

    c.check("a 90s segment is kept") {
        let s = seg("Chrome", 0, 90)
        try expectEq([s].meetingReviewFloor(floor).map(\.id), [s.id])
    }

    c.check("exactly 60s is kept — the floor is inclusive (>=), like minSegmentSeconds' own gate") {
        let s = seg("Chrome", 0, 60)
        try expectEq([s].meetingReviewFloor(floor).map(\.id), [s.id])
    }

    c.check("NON-contiguous brief glances never pool into a queue row — however many") {
        // Martin: a sub-grace visit never becomes a tracked switch, so its
        // identity is never worth asking about "even if we visited it
        // 1,000,000 times". Three separated 30s visits to one window must
        // NOT sum to a 90s decision.
        let a = seg("Chrome", 0, 30, title: "Insurance")
        let b = seg("Chrome", 100, 130, title: "Insurance")
        let d = seg("Chrome", 200, 230, title: "Insurance")
        try expect([a, b, d].meetingReviewFloor(floor).isEmpty,
                   "per-segment, never per-surface pooling")
    }

    c.check("a long visit qualifies alongside a vanishing glance") {
        // Contiguous same-surface time reaches the queue as ONE extended
        // segment, so a genuine 90s visit is a single ≥floor row; the
        // separate 30s glance at another window still vanishes.
        let long = seg("Chrome", 0, 90, title: "Insurance")
        let glance = seg("Chrome", 200, 230, title: "Tab B")
        try expectEq([long, glance].meetingReviewFloor(floor).map(\.id), [long.id])
    }

    c.check("unknownAssigned re-add respects the same rule over the combined pending+unknown array") {
        // runRetroPass re-adds Unknown-swept segments alongside the pending
        // queue and floors the COMBINED array: a sub-floor Unknown glance can
        // no more re-enter circulation than a pending one, while an Unknown
        // segment that is itself ≥floor stays reclaimable.
        let unknownTarget = Target.task(WorkTask.unknown.ref)
        let pending = seg("Chrome", 0, 90)
        let tinyUnknown = seg("Mail", 200, 230, assigned: unknownTarget)
        let bigUnknown = seg("Slack", 300, 380, assigned: unknownTarget)
        let combined = [pending, tinyUnknown, bigUnknown].meetingReviewFloor(floor)
        try expectEq(combined.map(\.id), [pending.id, bigUnknown.id],
                     "the 30s Unknown glance stays out; the 80s Unknown segment stays reclaimable")
    }

    c.check("floor 0 admits everything — the setting's off switch") {
        let s = seg("Mail", 0, 5)
        try expectEq([s].meetingReviewFloor(0).map(\.id), [s.id])
    }
}

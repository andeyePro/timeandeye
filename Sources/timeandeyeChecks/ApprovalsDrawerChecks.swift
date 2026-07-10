import Foundation
import timeandeyeCore

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
        let b1 = seg("Ghostty", 100, 160, title: "timeandeye")
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

    c.check("neither Unknown nor Clear teaches the attributor; a real task does") {
        try expect(!Target.task(unknownRef).teachesAttributor,
                   "explicit don't-know, not a correction")
        try expect(Target.task(.op(1)).teachesAttributor)
        // Flipped 2026-07-10 — Martin's Clear decision: "drop from this
        // list and don't add to timesheets … may be selected because the
        // user can't be bothered assigning 1m tracks — which the app
        // should not 'learn' from". The drawer's Clear/⌫/⌘D routes through
        // assignReview's teachesAttributor gate, so this flag being false
        // IS the no-sticky/no-learned-lean/no-clock-stop guarantee. The
        // timeline's "Don't track this" teaches via a separate direct path.
        try expect(!Target.doNotTrack.teachesAttributor,
                   "a Clear must never become a learned don't-track lean")
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

// MARK: - Slice detail (2026-07-10, Martin's drawer critique: "the one that
// it classifies as Oldest has no date or timestamp … Clicking on an entry
// should reveal 100% of the data you have on it … including what was
// tracked before and after"). The pure parts: the day classification the
// drawer's date labels ride on, the neighbour lookup with its gap
// indication, and per-slice assignment routing.

func reviewSliceDetailChecks(_ c: Checks) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 2026-07-09 12:00:00 UTC — a fixed midday "now".
    let noon = Date(timeIntervalSince1970: 1_783_598_400)

    c.check("RelativeDay classifies by CALENDAR day, not elapsed time") {
        try expectEq(RelativeDay.of(noon, now: noon, calendar: cal), .today)
        try expectEq(RelativeDay.of(noon.addingTimeInterval(-11 * 3600), now: noon, calendar: cal),
                     .today, "01:00 the same morning is Today, eleven hours later")
        try expectEq(RelativeDay.of(noon.addingTimeInterval(-13 * 3600), now: noon, calendar: cal),
                     .yesterday, "23:00 last night is Yesterday, only thirteen hours back")
        try expectEq(RelativeDay.of(noon.addingTimeInterval(-2 * 86_400), now: noon, calendar: cal),
                     .other, "two days back gets the calendar date")
    }

    c.check("just past midnight, a moment 40 minutes earlier is already Yesterday") {
        // The Oldest sort's whole point: the day boundary matters even when
        // barely any time has passed.
        let halfPastMidnight = noon.addingTimeInterval(-11.5 * 3600)   // 00:30
        let lateLastNight = halfPastMidnight.addingTimeInterval(-40 * 60)   // 23:50
        try expectEq(RelativeDay.of(lateLastNight, now: halfPastMidnight, calendar: cal), .yesterday)
    }

    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func session(_ task: TaskRef, _ start: TimeInterval, _ end: TimeInterval) -> Session {
        Session(task: task, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                certainty: 0.9)
    }

    c.check("neighbours: the NEAREST session each side wins, with its gap") {
        // Slice 1000–1600. Before candidates end at 400 and 940; after
        // candidates start at 1660 and 3000.
        let sessions = [session(.op(1), 0, 400), session(.op(2), 500, 940),
                        session(.op(3), 1660, 1800), session(.op(4), 3000, 3300)]
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600), in: sessions)
        let before = try unwrap(n.before)
        try expectEq(before.task, .op(2), "the later-ending session is the one actually adjacent")
        try expectEq(before.gap, 60)
        let after = try unwrap(n.after)
        try expectEq(after.task, .op(3))
        try expectEq(after.gap, 60)
    }

    c.check("contiguity: a gap at the tolerance still reads contiguous; past it gets the indicator") {
        let atTolerance = SliceNeighbours.Neighbour(task: .op(1), start: t0, end: t0,
                                                    gap: SliceNeighbours.contiguityTolerance)
        try expect(atTolerance.isContiguous, "the tracker's own switch grace can journal "
                   + "back-to-back activity seconds apart — under a minute is 'immediately'")
        let past = SliceNeighbours.Neighbour(task: .op(1), start: t0, end: t0,
                                             gap: SliceNeighbours.contiguityTolerance + 1)
        try expect(!past.isContiguous, "anything past the tolerance names its gap")
        let touching = SliceNeighbours.Neighbour(task: .op(1), start: t0, end: t0, gap: 0)
        try expect(touching.isContiguous)
    }

    c.check("a session overlapping the slice is never a neighbour — it IS the slice's own minutes") {
        // The low-certainty session journalled over the same span must not
        // be reported as "before" or "after" itself.
        let overlapping = session(.op(9), 500, 1200)     // straddles the slice start
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600), in: [overlapping])
        try expectNil(n.before)
        try expectNil(n.after)
    }

    c.check("empty sides stay nil — 'nothing tracked' is a fact, not a guess") {
        let n = SliceNeighbours.around(start: t0, end: t0.addingTimeInterval(60), in: [])
        try expectNil(n.before)
        try expectNil(n.after)
    }

    c.check("a session ending exactly at the slice start is the zero-gap before-neighbour") {
        let flush = session(.op(5), 0, 1000)
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600), in: [flush])
        let before = try unwrap(n.before)
        try expectEq(before.gap, 0)
        try expect(before.isContiguous)
    }

    c.check("per-slice assign routes ONE segment; its stack siblings stay queued as a stack") {
        let journal = InMemoryJournalStore()
        func seg(_ start: TimeInterval, _ end: TimeInterval) -> ReviewSegment {
            ReviewSegment(app: "Excel", windowTitle: "Budget.xlsx",
                          start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
        }
        let a = seg(0, 600), b = seg(1000, 1600), d = seg(2000, 2600)
        for s in [a, b, d] { try journal.save(s) }
        // The drawer's per-slice path: the same journal.assign the stack
        // path uses, scoped to one id.
        try journal.assign([b.id], to: .task(.op(7)))
        let remaining = try journal.pendingReview()
        try expectEq(remaining.map(\.id), [a.id, d.id], "only the picked slice left the queue")
        let stacks = remaining.stacked()
        try expectEq(stacks.count, 1, "the siblings still present as ONE surface decision")
        try expectEq(stacks.first?.segments.map(\.id), [a.id, d.id])
        // Undo's restore path (assign to nil) brings the slice back.
        try journal.assign([b.id], to: nil)
        try expectEq(try journal.pendingReview().count, 3)
    }

    c.check("a one-slice assign teaches from THAT slice's evidence only") {
        var mail = ReviewSegment(app: "Mail", windowTitle: "Inbox",
                                 start: t0, end: t0.addingTimeInterval(300))
        mail.correspondents = ["amy@x.co"]
        mail.emailSubject = "Renewal"
        var sibling = ReviewSegment(app: "Mail", windowTitle: "Inbox",
                                    start: t0.addingTimeInterval(1000),
                                    end: t0.addingTimeInterval(1300))
        sibling.correspondents = ["bob@y.co"]
        let signals = [mail, sibling].teachingSignals(for: [mail.id])
        try expectEq(signals.count, 1)
        try expectEq(signals.first?.correspondents, ["amy@x.co"],
                     "the sibling's evidence never bleeds into a single-slice teach")
    }

    // Pending-aware neighbours (Martin's retest, 2026-07-10: "Every item
    // shows a gap"). Root cause: the lookup only considered attributed
    // sessions, so a slice flush against ANOTHER pending slice reported a
    // gap to some distant tracked session. The display overload considers
    // both and picks whichever is nearest each side.

    func pendingSeg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
                    title: String? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title,
                      start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    c.check("a back-to-back PENDING slice is the neighbour, not a distant tracked session") {
        // Slice 1000–1600. The only session ended 600s before; a pending
        // slice ends flush at 1000. His every-item-gap complaint is exactly
        // this shape — the answer must be the touching pending slice.
        let far = session(.op(1), 0, 400)
        let queued = pendingSeg("Excel", 500, 1000, title: "Budget.xlsx")
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600),
                                       in: [far], pending: [queued])
        let before = try unwrap(n.before)
        try expect(before.isPending)
        try expectNil(before.task, "nothing is decided about a pending neighbour")
        try expectEq(before.pendingSurface, "Excel – Budget.xlsx")
        try expectEq(before.gap, 0)
        try expect(before.isContiguous, "flush pending neighbour = NO gap indicator")
    }

    c.check("a pending slice wins the AFTER side too, with its real gap") {
        let queued = pendingSeg("Excel", 1720, 2000)
        let far = session(.op(1), 3000, 3300)
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600),
                                       in: [far], pending: [queued])
        let after = try unwrap(n.after)
        try expect(after.isPending)
        try expectEq(after.gap, 120)
    }

    c.check("a nearer tracked session still beats a farther pending slice") {
        let near = session(.op(2), 500, 990)
        let farPending = pendingSeg("Excel", 0, 400)
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600),
                                       in: [near], pending: [farPending])
        let before = try unwrap(n.before)
        try expectEq(before.task, .op(2))
        try expect(!before.isPending)
    }

    c.check("an exact tie goes to the attributed session — a task name informs more") {
        let tied = session(.op(3), 500, 900)
        let tiedPending = pendingSeg("Excel", 400, 900)
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600),
                                       in: [tied], pending: [tiedPending])
        try expectEq(try unwrap(n.before).task, .op(3))
    }

    c.check("with no pending slices the display lookup matches the sessions-only one") {
        let sessions = [session(.op(1), 0, 940), session(.op(2), 1660, 1800)]
        let plain = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                           end: t0.addingTimeInterval(1600), in: sessions)
        let aware = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                           end: t0.addingTimeInterval(1600),
                                           in: sessions, pending: [])
        try expectEq(aware, plain)
    }

    c.check("a pending slice overlapping the slice (incl. itself) is never a neighbour") {
        // The caller filters the slice's own row out by id, but the edge
        // filters must exclude any overlapper regardless — a slice must
        // never read as its own neighbour.
        let overlapper = pendingSeg("Excel", 900, 1200)
        let n = SliceNeighbours.around(start: t0.addingTimeInterval(1000),
                                       end: t0.addingTimeInterval(1600),
                                       in: [], pending: [overlapper])
        try expectNil(n.before)
        try expectNil(n.after)
    }
}

// MARK: - Expand/collapse-all (Martin's retest, 2026-07-10: "Could we have
// an open-all option?"). Pure state maths for the drawer's header control:
// what "open everything" targets, and when the control should read
// "Collapse all" instead.

func reviewExpansionChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func seg(_ app: String, _ start: TimeInterval, _ end: TimeInterval,
             title: String? = nil) -> ReviewSegment {
        ReviewSegment(app: app, windowTitle: title,
                      start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }
    // Two stacks: Excel (two slices) + Mail (one slice).
    let a = seg("Excel", 0, 600, title: "Budget.xlsx")
    let b = seg("Excel", 1000, 1600, title: "Budget.xlsx")
    let m = seg("Mail", 2000, 2600, title: "Inbox")
    let stacks = [a, b, m].stacked()

    c.check("expand-all targets every stack AND every slice disclosure") {
        try expectEq(stacks.everyStackID.count, 2)
        try expectEq(stacks.everySliceID, Set([a.id, b.id, m.id]),
                     "open-all really opens everything, not just the stacks")
    }

    c.check("fully-expanded flips the control; one closed disclosure flips it back") {
        try expect(stacks.isFullyExpanded(stacks: stacks.everyStackID,
                                          slices: stacks.everySliceID))
        try expect(!stacks.isFullyExpanded(stacks: stacks.everyStackID,
                                           slices: [a.id, b.id]),
                   "a single closed slice detail means there is still something to open")
        try expect(!stacks.isFullyExpanded(stacks: [], slices: stacks.everySliceID))
    }

    c.check("ids of rows assigned away meanwhile don't wedge the control") {
        // Assign the Mail stack away: the view's sets still hold its ids.
        let remaining = [a, b].stacked()
        try expect(remaining.isFullyExpanded(stacks: stacks.everyStackID,
                                             slices: stacks.everySliceID),
                   "subset semantics — stale ids linger harmlessly")
    }

    c.check("an empty queue is never 'fully expanded' — nothing to collapse") {
        try expect(![ReviewSegment]().stacked().isFullyExpanded(stacks: [], slices: []))
    }
}

// MARK: - Adjacency certainty boost (Martin, 2026-07-10: "if the same
// activity is tracked immediately before and after a slice, that should
// significantly increase the slice's certainty of being the same
// activity"). Pure arithmetic + reasoning strings: what the assign
// buttons' order, percentages and hovers ride on. Display/ordering only —
// nothing here touches journalled certainty, so these checks are the whole
// behavioural contract.

func adjacencyBoostChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let alpha = TaskRef.op(1)

    /// A neighbour on the given task at the given gap — the boost only
    /// reads task + gap, so the timestamps can stay token.
    func near(_ task: TaskRef, gap: TimeInterval) -> SliceNeighbours.Neighbour {
        SliceNeighbours.Neighbour(task: task, start: t0, end: t0, gap: gap)
    }

    c.check("one contiguous same-task side closes 30% of the gap to the ceiling") {
        // base 0.45, ceiling 0.95: gap 0.5, one side closes 0.3 of it.
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: SliceNeighbours(before: near(alpha, gap: 0)))
        try expectClose(b.certainty, 0.60)
        try expectEq(b.reasoning, "follows Alpha (+15%)")
    }

    c.check("both contiguous same-task sides close 60%") {
        let n = SliceNeighbours(before: near(alpha, gap: 0), after: near(alpha, gap: 0))
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: n)
        try expectClose(b.certainty, 0.75)
        try expectEq(b.reasoning, "both neighbours Alpha (+30%)")
    }

    c.check("the after side reads 'followed by'") {
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: SliceNeighbours(after: near(alpha, gap: 0)))
        try expectClose(b.certainty, 0.60)
        try expectEq(b.reasoning, "followed by Alpha (+15%)")
    }

    c.check("the boost can never pass the inferred ceiling; a pin's 1.0 passes through untouched") {
        let n = SliceNeighbours(before: near(alpha, gap: 0), after: near(alpha, gap: 0))
        // Right at the ceiling: nothing left to close, no reasoning to show.
        let capped = AdjacencyBoost.apply(base: 0.95, candidate: .task(alpha), name: "Alpha",
                                          neighbours: n)
        try expectClose(capped.certainty, 0.95)
        try expectNil(capped.reasoning)
        // A pin (1.0) must stay the ONLY 1.0 — and must not be dragged DOWN
        // to the ceiling either.
        let pinned = AdjacencyBoost.apply(base: 1.0, candidate: .task(alpha), name: "Alpha",
                                          neighbours: n)
        try expectClose(pinned.certainty, 1.0)
        try expectNil(pinned.reasoning)
        // Near the ceiling the closed fraction shrinks with the gap.
        let close = AdjacencyBoost.apply(base: 0.90, candidate: .task(alpha), name: "Alpha",
                                         neighbours: n)
        try expectClose(close.certainty, 0.93)
    }

    c.check("'immediately' decays: full at the 30s switch buffer, zero at 15 min, linear between") {
        // At the buffer: still full strength.
        let atBuffer = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                            neighbours: SliceNeighbours(before: near(alpha, gap: 30)))
        try expectClose(atBuffer.certainty, 0.60)
        // At 15 min: no boost at all, and no reasoning pretending otherwise.
        let atLimit = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                           neighbours: SliceNeighbours(before: near(alpha, gap: 900)))
        try expectClose(atLimit.certainty, 0.45)
        try expectNil(atLimit.reasoning)
        // Midway (465s): half strength → 0.3·0.5 of the 0.5 gap = +0.075,
        // and the reasoning names the gap so the smaller number reads fair.
        let midway = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                          neighbours: SliceNeighbours(before: near(alpha, gap: 465)))
        try expectClose(midway.certainty, 0.525)
        // (+7%: the exact half-point 7.5 lands a hair below it in binary
        // floating point — a one-point display nuance, not a tuning fact.)
        try expectEq(midway.reasoning, "follows Alpha (8m gap, +7%)")
    }

    c.check("two-sided decay averages the sides and hands over continuously to one-sided") {
        // One side full, the other half-decayed: 0.6·(1+0.5)/2 = 0.45 of the gap.
        let n = SliceNeighbours(before: near(alpha, gap: 0), after: near(alpha, gap: 465))
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: n)
        try expectClose(b.certainty, 0.675)
        try expectEq(b.reasoning, "both neighbours Alpha (gaps up to 8m, +22%)")
        // One side fully decayed = exactly the one-sided value: no cliff as
        // a neighbour's gap crosses the 15-min limit.
        let handover = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                            neighbours: SliceNeighbours(before: near(alpha, gap: 0),
                                                                        after: near(alpha, gap: 900)))
        try expectClose(handover.certainty, 0.60)
    }

    c.check("only the SAME task boosts; .doNotTrack never does") {
        let other = SliceNeighbours(before: near(.op(2), gap: 0), after: near(.op(2), gap: 0))
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: other)
        try expectClose(b.certainty, 0.45)
        try expectNil(b.reasoning)
        let dnt = AdjacencyBoost.apply(base: 0.45, candidate: .doNotTrack, name: "Do not track",
                                       neighbours: SliceNeighbours(before: near(alpha, gap: 0)))
        try expectClose(dnt.certainty, 0.45, "a neighbour is evidence FOR a task, never against tracking")
    }

    c.check("a PENDING neighbour never boosts any candidate — evidence of nothing") {
        // Martin, 2026-07-10: adjacency boosts ride on ATTRIBUTED sessions
        // only. The controller feeds AdjacencyBoost the sessions-only
        // lookup; this pins the defensive layer — even if a pending
        // neighbour (task nil) ever reached apply, it matches no candidate.
        let pendingSide = SliceNeighbours.Neighbour(task: nil, start: t0, end: t0, gap: 0,
                                                    pendingSurface: "Excel – Budget.xlsx")
        let b = AdjacencyBoost.apply(base: 0.45, candidate: .task(alpha), name: "Alpha",
                                     neighbours: SliceNeighbours(before: pendingSide,
                                                                 after: pendingSide))
        try expectClose(b.certainty, 0.45)
        try expectNil(b.reasoning)
    }

    c.check("assigning the odd slice away IMPROVES the remaining group's button") {
        // Martin's retest flow: assign individual slices out of a group,
        // then assign the rest as one. "If that increases the chances of
        // all members of a group belonging to one task, the chances for
        // the group in the assign buttons should improve" — the mean over
        // the REMAINING slices must rise once the low scorer leaves. (The
        // controller recomputes because its memo is keyed by the segment-id
        // set, which shrinks — plus reloadReview clears it on every assign.)
        let strong = AdjacencyBoost(base: 0.60, certainty: 0.80, reasoning: "both neighbours Alpha (+20%)")
        let alsoStrong = AdjacencyBoost(base: 0.55, certainty: 0.70, reasoning: "follows Alpha (+15%)")
        let odd = AdjacencyBoost(base: 0.10, certainty: 0.10)
        let whole = AdjacencyBoost.aggregate([strong, alsoStrong, odd])
        let remaining = AdjacencyBoost.aggregate([strong, alsoStrong])
        try expect(remaining.certainty > whole.certainty,
                   "the group's certainty must recompute upward once the outlier is assigned away")
        try expectEq(remaining.reasoning, "adjacency on every slice (both neighbours Alpha (+20%))")
    }

    c.check("a defensive negative gap reads as touching, never as negative strength") {
        try expectClose(AdjacencyBoost.strength(gap: -5), 1.0)
        try expectClose(AdjacencyBoost.strength(gap: 0), 1.0)
    }

    c.check("stack aggregation is the MEAN, with an honest slice count in the reasoning") {
        // Mean, not max: the button answers "how sure are we ALL these
        // slices are this task" — one strong slice must not oversell.
        let boosted = AdjacencyBoost(base: 0.45, certainty: 0.60, reasoning: "follows Alpha (+15%)")
        let plain = AdjacencyBoost(base: 0.50, certainty: 0.50)
        let agg = AdjacencyBoost.aggregate([boosted, plain])
        try expectClose(agg.base, 0.475)
        try expectClose(agg.certainty, 0.55)
        try expectEq(agg.reasoning, "adjacency on 1 of 2 slices (follows Alpha (+15%))")
        let all = AdjacencyBoost.aggregate([boosted, boosted])
        try expectEq(all.reasoning, "adjacency on every slice (follows Alpha (+15%))")
        let single = AdjacencyBoost.aggregate([boosted])
        try expectEq(single, boosted, "one slice aggregates to itself, fragment untouched")
        let none = AdjacencyBoost.aggregate([])
        try expectClose(none.certainty, 0)
        try expectNil(none.reasoning)
    }

    c.check("hover text builds base source + adjacency + result; stacks announce the mean") {
        let boosted = AdjacencyBoost(base: 0.45, certainty: 0.60, reasoning: "follows Alpha (+15%)")
        try expectEq(AdjacencyBoost.hoverText(sourceWord: "learned associations + priors",
                                              boosted, sliceCount: 1),
                     "learned associations + priors 45% · follows Alpha (+15%) → 60%")
        let plain = AdjacencyBoost(base: 0.45, certainty: 0.45)
        try expectEq(AdjacencyBoost.hoverText(sourceWord: "learned associations + priors",
                                              plain, sliceCount: 1),
                     "learned associations + priors 45%")
        try expectEq(AdjacencyBoost.hoverText(sourceWord: "learned associations + priors",
                                              boosted, sliceCount: 3),
                     "mean of 3 slices · learned associations + priors 45% · follows Alpha (+15%) → 60%")
    }

    c.check("button order: descending certainty, original pick-list position breaking ties") {
        try expectEq(AdjacencyBoost.buttonOrder(certainties: [0.2, 0.9, 0.2, 0.0]),
                     [1, 0, 2, 3], "the tie between the two 0.2s keeps pick-list order")
        try expectEq(AdjacencyBoost.buttonOrder(certainties: []), [])
        try expectEq(AdjacencyBoost.buttonOrder(certainties: [0, 0, 0]), [0, 1, 2],
                     "an unscored list is untouched — the familiar ranked order survives")
    }
}

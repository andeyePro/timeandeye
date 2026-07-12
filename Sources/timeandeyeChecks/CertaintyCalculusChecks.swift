import Foundation
import timeandeyeCore

// MARK: - The attribution calculus, pinned as PROPERTIES not examples
// (docs/superpowers/specs/2026-07-12-attribution-calculus.md). One number —
// `certainty` in [0, 1] — is produced, folded, mutated, compared and shown by
// the whole engine; these seven properties are the conformance contract. Where
// a producer path is a controller write not reachable from a Core check
// (timeline reassign, Unknown-sweep, review confirm), the call site is named
// in a comment and the human-word CONSTANT it writes is pinned here.

/// Deterministic SplitMix64 — the checks house style forbids a system RNG in a
/// property check (a flake is a false failure). Seeded, reproducible.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func certaintyCalculusChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "build", status: "Now"),
                 WorkTask(ref: .op(2), subject: "review", status: "Next")]
    func opPage(_ id: Int) -> ActivitySignal {
        ActivitySignal(app: "Chrome", windowTitle: "WP \(id)",
                       tabURL: "https://op.example.com/work_packages/\(id)", timestamp: now)
    }
    let ghostty = ActivitySignal(app: "Ghostty", windowTitle: "build", timestamp: now)
    func mail(_ who: [String]) -> ActivitySignal {
        ActivitySignal(app: "Google Chrome", windowTitle: "Renewal",
                       tabURL: "https://mail.google.com/mail/u/0/#inbox/x",
                       timestamp: now, correspondents: who, emailSubject: "Renewal")
    }

    // MARK: P1 — tier ceilings: every producer path lands at or under its
    // tier's ceiling; only human-word paths produce 1.0.

    c.check("P1: every attribute() producer path lands under its tier ceiling; only a pin (human word) is 1.0") {
        // Ranked tier (<= rankedCeiling).
        let ranked = Attributor(instanceHost: host).attribute(ghostty, tasks: tasks, now: now)
        try expect(ranked.certainty <= Attributor.rankedCeiling,
                   "uncorroborated ranking caps at rankedCeiling (got \(ranked.certainty))")
        try expect(ranked.certainty < Attributor.humanWord, "ranked is never 1.0")

        // Inferred tier (<= inferredCeiling): URL, title, email rule, primed
        // surface all cap at the ceiling constant.
        let url = Attributor(instanceHost: host).attribute(opPage(1), tasks: tasks, now: now)
        try expectClose(url.certainty, Attributor.inferredCeiling)

        let emailA = Attributor(instanceHost: host)
        emailA.learnEmailRule(mail(["r@harborlane.example"]), to: .op(1))
        let email = emailA.attribute(mail(["a@harborlane.example"]), tasks: tasks, now: now)
        try expectClose(email.certainty, Attributor.inferredCeiling)

        let primedA = Attributor(instanceHost: host)
        primedA.assign(ghostty, target: .task(.op(2)))
        let primed = primedA.attribute(ghostty, tasks: tasks, now: now)
        try expectClose(primed.certainty, Attributor.inferredCeiling)

        // Pending prime is a HYPOTHESIS: below the inferred rules, well under 1.0.
        let pendA = Attributor(instanceHost: host)
        _ = pendA.attribute(opPage(1), tasks: tasks, now: now)
        pendA.noteDwell(ghostty, at: now)
        let pend = pendA.attribute(ghostty, tasks: tasks, now: now)
        try expect(pend.certainty <= Attributor.inferredCeiling)
        try expect(pend.certainty < Attributor.humanWord)

        // Adjacency-corroborated lift: a ranked candidate crosses INTO the
        // inferred tier but never past its ceiling (spec boundary rule 1).
        let boostA = Attributor(instanceHost: host)
        let boosted = boostA.attribute(ghostty, tasks: tasks, now: now,
            continuity: .init(target: .task(.op(1)), lastActive: now))
        try expect(boosted.ranked.allSatisfy { $0.score <= Attributor.inferredCeiling },
                   "an adjacency lift caps at inferredCeiling, never above")

        // Human word: a pin is exactly 1.0 — the ONLY 1.0 the engine derives.
        let pinA = Attributor(instanceHost: host)
        pinA.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(1)))
        let pinned = pinA.attribute(ghostty, tasks: tasks, now: now)
        try expectClose(pinned.certainty, Attributor.humanWord)
    }

    // MARK: P2 — floor: no journalled certainty is negative, whatever the
    // prior penalties. A field of only others'-tasks (the −10 ranking penalty)
    // must clamp to 0, never flow through as a negative confidence.

    c.check("P2: a candidate field of only others'-tasks yields certainty >= 0, never negative") {
        let ranker = TaskRanker(config: RankingConfig(currentUser: "me"))
        let a = Attributor(instanceHost: host, ranker: ranker)
        // Every task belongs to someone else and was never tracked → score −10
        // each → priorPart negative before the floor clamp.
        let others = [WorkTask(ref: .op(1), subject: "theirs A", status: "Open", assignee: "them"),
                      WorkTask(ref: .op(2), subject: "theirs B", status: "Open", assignee: "them")]
        let result = a.attribute(ghostty, tasks: others, now: now)
        try expect(result.certainty >= 0, "best is floored at 0 (got \(result.certainty))")
        try expect(result.ranked.allSatisfy { $0.score >= 0 },
                   "no ranked candidate is negative — a penalty is a sort key, not a confidence")
    }

    // MARK: P3 — human word: pin, manual start, confirm, reassign, sweep-repoint
    // all yield exactly 1.0. Core-reachable here: the pin producer and the
    // tracker's manual start. The controller human-word writes are pinned by
    // the CONSTANT they all share (Attributor.humanWord) and named by call
    // site: confirmViewedSlices (AppController ~2256), applyTimelineEdit task-
    // change (~4412), reassignTimelineSessions (~4549), repointSessionsToUnknown
    // (~2149) — grep `= Attributor.humanWord` in timeandeyeMac.

    c.check("P3: manual start and a pin both write exactly the human-word 1.0") {
        try expectClose(Attributor.humanWord, 1.0, "the human-word tier IS 1.0")
        let a = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: a, config: TrackerConfig()) { tasks }
        tracker.start(task: .op(1), at: now)
        guard case .tracking(_, let cert) = tracker.state else {
            throw CheckFailure(description: "start must leave the tracker tracking")
        }
        try expectClose(cert, Attributor.humanWord, "manual start is the user's word")

        let pinA = Attributor(instanceHost: host)
        pinA.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])), task: .op(1)))
        try expectClose(pinA.attribute(ghostty, tasks: tasks, now: now).certainty, Attributor.humanWord)
    }

    // MARK: P4 — ownership: a task-changing mutation REPLACES certainty; a
    // same-task confidence event never lowers it.

    c.check("P4: contradiction refile REPLACES certainty with the re-derived score, never max(old,new)") {
        let t0 = now
        let session = Session(task: .op(1), start: t0, end: t0.addingTimeInterval(600), certainty: 0.9)
        // A LOWER new score still replaces — the old task's confidence must not
        // inflate the new target's.
        let down = ContradictionRefile.apply(
            ContradictionRefile.Finding(sessionID: session.id, priorTask: .op(1),
                                        priorCertainty: 0.9, newTask: .op(2), score: 0.3),
            to: session)
        try expectClose(down.certainty, 0.3, "replace, even downward — not max(0.9, 0.3)")
        try expectEq(down.newTask, .op(2), "the repoint changes the task")
    }

    c.check("P4: a retro lift never lowers certainty and skips pushed slices (the gained pushed-guard)") {
        let t0 = now
        let segment = ReviewSegment(app: "Chrome", start: t0, end: t0.addingTimeInterval(600))
        let low = Session(task: .op(9), start: t0, end: t0.addingTimeInterval(600), certainty: 0.5)
        let plan = RetroAcceptance.plan(pending: [segment], sessions: [low], bar: 0.8) { _ in
            (target: .task(.op(1)), score: 0.9)
        }
        let lift = try unwrap(plan.lifts.first)
        try expect(lift.newCertainty >= lift.priorCertainty, "monotone up")
        try expectClose(lift.newCertainty, 0.9, "below-bar gate + at-bar clearance ⇒ max == score")
        // The lift gate GAINED !pushedToOP: an already-posted below-bar session
        // must not be re-scored off a bulk pass.
        let pushed = Session(task: .op(9), start: t0, end: t0.addingTimeInterval(600),
                             certainty: 0.5, pushedToOP: true)
        let pushedPlan = RetroAcceptance.plan(pending: [segment], sessions: [pushed], bar: 0.8) { _ in
            (target: .task(.op(1)), score: 0.9)
        }
        try expect(pushedPlan.lifts.isEmpty, "a pushed session never lifts")
    }

    // MARK: P5 — fold: every many-to-one fold equals the DURATION-WEIGHTED MEAN
    // (spec §Folds), over randomised (seeded, deterministic) span sets. The
    // three coalescing paths — flush, prune, merge — now share the one rule.

    c.check("P5: mergeAdjacent and JournalPrune fold certainty by the duration-weighted mean") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let planNow = Date(timeIntervalSince1970: 1_750_000_000)
        for seed in UInt64(1)...UInt64(24) {
            var rng = SeededRNG(seed: seed)
            let count = Int.random(in: 2...6, using: &rng)
            // Contiguous same-task pieces on ONE old day, so extent == Σ
            // durations and the weighted mean is exact.
            let dayStart = cal.startOfDay(for: planNow.addingTimeInterval(-800 * 86_400))
                .addingTimeInterval(3600)
            var cursor = dayStart
            var pieces: [Session] = []
            var weighted = 0.0, total = 0.0
            for _ in 0..<count {
                let dur = TimeInterval(Int.random(in: 60...900, using: &rng))
                let cert = Double.random(in: 0.0...1.0, using: &rng)
                pieces.append(Session(task: .op(1), start: cursor,
                                      end: cursor.addingTimeInterval(dur),
                                      certainty: cert, pushedToOP: true))
                weighted += cert * dur; total += dur
                cursor = cursor.addingTimeInterval(dur)
            }
            let expected = weighted / total

            let merged = TimelineMath.mergeAdjacent(pieces)
            try expectEq(merged.count, 1, "seed \(seed): contiguous same-task ⇒ one row")
            try expectClose(merged[0].certainty, expected, accuracy: 0.0005,
                            "seed \(seed): mergeAdjacent = weighted mean")

            let plan = JournalPrune.plan(sessions: pieces, olderThanDays: 730,
                                         now: planNow, calendar: cal)
            let rollup = try unwrap(plan.create.first)
            try expectClose(rollup.certainty, expected, accuracy: 0.0005,
                            "seed \(seed): JournalPrune = weighted mean")
        }
    }

    // MARK: P6 — one gate: the retro/walk/sweep eligibility predicate is a
    // single shared function (RetroEligibility) and excludes pushed slices.
    // Call sites (all use RetroEligibility): RetroAcceptance.plan's lift gate,
    // UnknownSweep.sessionsToRepoint, ReviewConfirm.plan's stamp gate.

    c.check("P6: RetroEligibility is (unpushed && certainty < bar && overlaps) — the whole truth table") {
        let t0 = now
        let seg = (start: t0, end: t0.addingTimeInterval(600))
        func session(cert: Double, pushed: Bool, overlapping: Bool) -> Session {
            let s = overlapping ? t0 : t0.addingTimeInterval(10_000)
            return Session(task: .op(1), start: s, end: s.addingTimeInterval(600),
                           certainty: cert, pushedToOP: pushed)
        }
        // The one eligible corner and each single-flip disqualifier.
        try expect(RetroEligibility.eligible(session(cert: 0.5, pushed: false, overlapping: true),
                                             below: 0.8, segStart: seg.start, segEnd: seg.end),
                   "unpushed + below bar + overlapping ⇒ eligible")
        try expect(!RetroEligibility.eligible(session(cert: 0.5, pushed: true, overlapping: true),
                                              below: 0.8, segStart: seg.start, segEnd: seg.end),
                   "pushed ⇒ never")
        try expect(!RetroEligibility.eligible(session(cert: 0.9, pushed: false, overlapping: true),
                                              below: 0.8, segStart: seg.start, segEnd: seg.end),
                   "at/above bar ⇒ never")
        try expect(!RetroEligibility.eligible(session(cert: 0.5, pushed: false, overlapping: false),
                                              below: 0.8, segStart: seg.start, segEnd: seg.end),
                   "non-overlapping ⇒ never")
        // anyOf mirror: exactly the same three-part gate over a segment set.
        let segments = [ReviewSegment(app: "Chrome", start: seg.start, end: seg.end)]
        try expect(RetroEligibility.eligible(session(cert: 0.5, pushed: false, overlapping: true),
                                             below: 0.8, anyOf: segments))
        try expect(!RetroEligibility.eligible(session(cert: 0.5, pushed: true, overlapping: true),
                                              below: 0.8, anyOf: segments))
    }

    // MARK: P7 — ordering: the threshold ordering holds at both slider extremes
    // and at the sentinel.

    c.check("P7: threshold ordering at slider min (0.5), default (0.8), max-legal (1.0) and the 1.01 sentinel") {
        let switchBar = TrackerConfig.switchBar
        let idleResume = TrackerConfig.idleResumeBar
        let ranked = Attributor.rankedCeiling
        let inferred = Attributor.inferredCeiling
        let human = Attributor.humanWord

        // The config-INDEPENDENT constant chain always holds.
        try expect(0 <= switchBar, "0 ≤ switchBar")
        try expect(switchBar < idleResume, "switchBar (0.6) < idleResumeBar (0.9)")
        try expect(idleResume <= ranked, "idleResumeBar ≤ rankedCeiling")
        try expect(ranked < inferred, "rankedCeiling < inferredCeiling")
        try expect(inferred < human, "inferredCeiling < 1.0")

        // Default push bar 0.8: the spec's central chain switchBar < push ≤
        // idleResumeBar.
        let def = AndeyeSettings.certaintyAutoPushDefault
        try expectClose(def, 0.8)
        try expect(switchBar < def && def <= idleResume && def <= ranked,
                   "at 0.8: switchBar < push ≤ idleResumeBar/rankedCeiling")

        // Slider MIN 0.5: below the switch bar — the one relaxation the fixed
        // chain cannot hold at (0.5 < switchBar 0.6). Legal, and the review bar
        // simply admits everything above 0.5.
        try expect(0.5 < switchBar, "at the slider floor 0.5, push sits BELOW switchBar (documented relaxation)")

        // Max-legal 1.0: a human-word slice (1.0) still clears the bar, so the
        // user's word always auto-pushes.
        try expect(human >= 1.0, "a 1.0 human-word slice is push-eligible at push = 1.0")

        // 1.01 sentinel: no producible certainty reaches it (max is 1.0), so
        // nothing auto-pushes — "never".
        try expect(human < 1.01, "the 1.01 sentinel sits above every producible certainty ⇒ never auto-push")
    }
}

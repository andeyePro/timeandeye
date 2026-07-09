import Foundation
import andeyeTTCore

// MARK: - SessionTracker (plan task 8)

func sessionTrackerChecks(_ c: Checks) {
    // t(n) = n seconds after a minute-aligned base (1_750_000_080 = 29_166_668 × 60)
    let base = Date(timeIntervalSince1970: 1_750_000_080)
    func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "andeyeTT", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment", status: "Next")]

    func sig(_ app: String, _ title: String, at: TimeInterval, url: String? = nil) -> ActivitySignal {
        ActivitySignal(app: app, windowTitle: title, tabURL: url, timestamp: t(at))
    }

    func makeTracker(config: TrackerConfig = TrackerConfig()) -> (SessionTracker, Attributor) {
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: config) { tasks }
        return (tracker, attributor)
    }

    c.check("dominant-minute sessions") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 50)))   // op(1) dominates min 0
        tracker.handle(.input(t(115)))   // > 60 s floor since the t50 switch: it commits
        tracker.stop(at: t(130))

        // Instant switch: the boundary is the actual switch moment (t50),
        // not a minute-aligned approximation.
        try expectEq(sessions.count, 2)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(50))
        try expectEq(sessions[1].task, .op(2))
        try expectEq(sessions[1].start, t(50))
        try expectEq(sessions[1].end, t(130))
    }

    c.check("rapid window-flitting does not commit a pile of sub-minute slices") {
        // Three distinct surfaces → three distinct tasks (soft primes at 0.95,
        // below the 0.96 instant-commit). The user flits A→B→C→A in seconds,
        // then settles on A. Only A should be tracked; the brief B/C excursions
        // must NOT each become their own sub-minute slice.
        let tasks3 = [WorkTask(ref: .op(1), subject: "A", status: "Now"),
                      WorkTask(ref: .op(2), subject: "B", status: "Next"),
                      WorkTask(ref: .op(3), subject: "C", status: "Open")]
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: TrackerConfig()) { tasks3 }
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("X", "A", at: 0), task: .op(1))
        attributor.confirm(sig("X", "B", at: 0), task: .op(2))
        attributor.confirm(sig("X", "C", at: 0), task: .op(3))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("X", "A", at: 0)))
        tracker.handle(.focus(sig("X", "B", at: 3)))     // 3 s flit
        tracker.handle(.focus(sig("X", "C", at: 6)))     // 3 s flit — must NOT commit B
        tracker.handle(.focus(sig("X", "A", at: 9)))     // back to A
        tracker.handle(.focus(sig("X", "A", at: 120)))   // A held long
        tracker.stop(at: t(180))

        try expect(!sessions.contains { $0.task == .op(2) }, "brief flit to B must not be its own slice")
        try expect(!sessions.contains { $0.task == .op(3) }, "brief flit to C must not be its own slice")
        try expectEq(sessions.filter { $0.task == .op(1) }.count, 1, "A is one continuous slice")
        try expectEq(sessions.first?.start, t(0))
        try expectEq(sessions.last?.end, t(180))
    }

    c.check("flitting through a non-work tab and back does not auto-stop the clock") {
        let (tracker, attributor) = makeTracker()
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Steam", "Library", at: 5)))      // brief non-work flit
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 10)))  // back to work within grace
        tracker.handle(.input(t(60)))   // well past grace from the non-work pend at t5
        if case .stopped = tracker.state {
            try expect(false, "returning to work must cancel the pending non-work stop")
        }
    }

    c.check("a brief flit to a PINNED window folds back, not fragmenting the base task") {
        // Both windows are pinned (score 1.0). Before the fix the pin bypassed
        // the grace window and instant-committed on every flit, splitting op(1)
        // into pieces with floored gaps between. Now a brief flit to a pinned
        // window folds back, so op(1) stays one continuous slice.
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: TrackerConfig()) { tasks }
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["A"])), task: .op(1)))
        attributor.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["B"])), task: .op(2)))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("A", "x", at: 0)))
        tracker.handle(.focus(sig("A", "x", at: 300)))    // 5 min on op(1)
        tracker.handle(.focus(sig("B", "y", at: 300)))    // flit to a pinned op(2) window
        tracker.handle(.focus(sig("A", "x", at: 305)))    // 5 s flit → back to op(1)
        tracker.handle(.focus(sig("A", "x", at: 600)))
        tracker.stop(at: t(660))

        try expect(!sessions.contains { $0.task == .op(2) },
                   "the 5 s flit to a pinned window must fold, not commit")
        try expectEq(sessions.filter { $0.task == .op(1) }.count, 1,
                     "op(1) stays one continuous slice — no fragmentation, no gap")
    }

    c.check("uncertain time sticks to last task and queues coalesced review") {
        let (tracker, _) = makeTracker()
        var reviews: [ReviewSegment] = []
        var sawLowCertaintyOnOp1 = false
        tracker.onReview = { reviews.append($0) }
        tracker.onState = { state in
            if case .tracking(.task(.op(1)), let cert) = state, cert < 0.6 {
                sawLowCertaintyOnOp1 = true
            }
        }

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Mystery", "???", at: 0)))           // unknown -> uncertain
        tracker.handle(.focus(sig("Mystery", "???", at: 30)))          // same surface, coalesces
        tracker.handle(.focus(sig("Other", "thing", at: 60)))          // new surface, 25 s
        tracker.handle(.focus(sig("Other", "thing2", at: 85)))         // 5 s < minSegment: dropped
        tracker.stop(at: t(90))

        try expect(sawLowCertaintyOnOp1, "must keep attributing to op(1) at low certainty")
        try expectEq(reviews.count, 2)
        try expectEq(reviews[0].app, "Mystery")
        try expectEq(reviews[0].start, t(0))
        try expectEq(reviews[0].end, t(60), "coalesced across the two Mystery spans")
        try expectEq(reviews[1].app, "Other")
        try expectEq(reviews[1].windowTitle, "thing")
        try expectEq(reviews[1].end, t(85), "the 5 s thing2 span was dropped")
    }

    c.check("confident non-work auto-stops") {
        let (tracker, attributor) = makeTracker()
        var states: [TrackerState] = []
        tracker.onState = { states.append($0) }
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Steam", "Library", at: 30)))
        try expect(states.last != .stopped, "non-work within grace must not stop yet")
        tracker.handle(.focus(sig("Steam", "Library", at: 70)))   // grace elapsed
        try expectEq(states.last, .stopped)
    }

    c.check("leisure option tracks locally instead") {
        let leisure = TaskRef.local(UUID())
        var config = TrackerConfig()
        config.nonWorkTracksLocally = true
        config.leisureTask = leisure
        let (tracker, attributor) = makeTracker(config: config)
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Steam", "Library", at: 30)))
        tracker.handle(.focus(sig("Steam", "Library", at: 70)))   // grace elapsed
        guard case .tracking(.task(leisure), _) = tracker.state else {
            throw CheckFailure(description: "expected tracking leisure task, got \(tracker.state)")
        }
    }

    c.check("idle retro-trims and prompts on next input") {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 600
        let (tracker, attributor) = makeTracker(config: config)
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(40)))
        tracker.handle(.input(t(700)))   // 660 s gap > 600

        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].end, t(40), "session must trim back to last input")
        try expectEq(prompts, [.resumeAfterIdle(stoppedAt: t(40))])
    }

    c.check("sleep trims and wake prompts") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(50)))
        tracker.handle(.willSleep(t(120)))
        tracker.handle(.didWake(t(3000)))

        try expectEq(sessions.first?.end, t(50))
        try expectEq(prompts, [.resumeAfterIdle(stoppedAt: t(50))])
    }

    c.check("sleep within grace continues; longer sleep stops as of sleep") {
        let (tracker, attributor) = makeTracker()   // default sleepGrace = 60 s
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(50)))
        tracker.handle(.willSleep(t(60)))
        tracker.handle(.didWake(t(100)))    // 40 s < grace: keep tracking
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "wake within grace must continue, got \(tracker.state)")
        }
        try expect(sessions.isEmpty, "a within-grace sleep flushes nothing")
        try expect(prompts.isEmpty, "a within-grace sleep prompts nothing")

        tracker.handle(.input(t(120)))
        tracker.handle(.willSleep(t(130)))
        tracker.handle(.didWake(t(400)))    // 270 s > grace: stop as of last activity
        try expectEq(tracker.state, .stopped)
        try expectEq(sessions.last?.end, t(120), "long sleep stops as of last activity")
        try expect(prompts.contains { $0 == .resumeAfterIdle(stoppedAt: t(120)) },
                   "long sleep prompts to resume")
    }

    c.check("locked screen records no window detail") {
        let (tracker, attributor) = makeTracker()
        var spans: [FocusSpan] = []
        tracker.onSpanClosed = { spans.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))   // opens a span
        tracker.handle(.screenLocked(t(30)))                        // closes it at 30
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 60)))  // ignored while locked
        tracker.handle(.screenUnlocked(t(90)))
        tracker.stop(at: t(120))

        try expect(!spans.isEmpty, "the pre-lock span should still be recorded")
        try expect(spans.allSatisfy { $0.end <= t(30) },
                   "no window span may cover the locked 30..90 stretch")
    }

    c.check("brief uncertain patch does not sink session certainty (weighted mean)") {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 3600   // scripted gaps must not read as idle
        let (tracker, attributor) = makeTracker(config: config)
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))      // 19 min at 0.95
        tracker.handle(.focus(sig("Mystery", "???", at: 1140)))        // 1 min uncertain
        tracker.stop(at: t(1200))

        try expectEq(sessions.count, 1)
        try expect(sessions[0].certainty >= 0.8,
                   "weighted certainty must clear the push threshold; got \(sessions[0].certainty)")
        try expect(sessions[0].certainty < 0.95, "but the uncertain minute must count")
    }

    c.check("OP page auto-starts after a non-manual stop; manual stop is fully sticky") {
        let (tracker, _) = makeTracker()
        // URL signal from the initial (non-manual) stopped state → auto-starts
        tracker.handle(.focus(sig("Chrome", "WP", at: 0,
                                  url: "https://op.example.com/work_packages/1")))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "URL signal must auto-start, got \(tracker.state)")
        }
        tracker.stop(at: t(10), manual: false)   // idle/auto stop
        // PWA title signal (id lives in the app name) auto-starts after idle stop
        tracker.handle(.focus(ActivitySignal(app: "#2: Investment | OpenProject",
                                             timestamp: t(20))))
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "title signal must auto-start, got \(tracker.state)")
        }
        tracker.stop(at: t(30))   // MANUAL → sticky
        // After a manual stop, NOT EVEN a direct OP-page signal restarts it.
        tracker.handle(.focus(sig("Chrome", "WP", at: 40,
                                  url: "https://op.example.com/work_packages/1")))
        try expectEq(tracker.state, .stopped, "manual stop must be fully sticky")
    }

    c.check("sub-grace excursion stays in the prior slice (not a separate one)") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))  // 10s excursion (< grace)
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 110)))    // back within grace → revert
        tracker.stop(at: t(180))

        // One op(1) slice spanning the whole stretch — the Investment dip is a
        // window inside it, recorded as op(1) (what the menu bar promised once
        // we returned before grace).
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(180))
    }

    c.check("liveSliceStart is unchanged across a sub-grace excursion + revert") {
        // The menu bar reads its clock off liveSliceStart; a sub-grace excursion
        // that re-tags spans back to the base task must NOT move that start, or
        // the menu under-counts versus what flushes to OP.
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        let before = tracker.liveSliceStart
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))  // 10s excursion (< grace)
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 110)))    // back within grace → revert
        try expectEq(before, t(0), "live slice begins at the start of tracking")
        try expectEq(tracker.liveSliceStart, before,
                     "a reverted sub-grace excursion must not move liveSliceStart")
    }

    c.check("a sub-minute excursion past the old grace still folds back (no 0:00 slice)") {
        // The reported bug: a ~45 s dip into another window (longer than the 30 s
        // Switch Buffer, but under a displayed minute) committed as its own slice
        // and showed "0:00". The floor is now a full minute, so it folds back.
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))  // excursion begins
        tracker.handle(.input(t(135)))                                 // 35 s in — past old grace
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 145)))    // back at 45 s → folds
        tracker.stop(at: t(240))

        try expect(!sessions.contains { $0.task == .op(2) },
                   "a sub-minute excursion must not become its own slice")
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(240))
    }

    c.check("a 61-120s started slice survives a Switch Buffer above 60s (not dropped)") {
        // Keystone: SettingsView allows the buffer up to 120s. A slice the user
        // deliberately started that runs 65s then is switched off is WORK; the
        // old flush floor (== buffer) silently dropped it for buffer>60.
        var config = TrackerConfig()
        config.switchGraceSeconds = 90
        let (tracker, attributor) = makeTracker(config: config)
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 65)))   // switch away at 65 s
        tracker.handle(.input(t(160)))   // B held 95 s > sliceFloor(90) → commits, flushes A[0,65]
        tracker.stop(at: t(220))

        let a = sessions.first { $0.task == .op(1) }
        try expect(a != nil, "the 65 s started slice is work, not a dropped flit")
        try expectEq(a?.start, t(0))
        try expectEq(a?.end, t(65))
    }

    c.check("display follows the window instantly even while the switch is provisional") {
        let (tracker, attributor) = makeTracker()
        var states: [TrackerState] = []
        tracker.onState = { states.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))   // provisional
        // The menu bar shows op(2) immediately (what would be recorded if held)…
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "display should follow to op(2), got \(tracker.state)")
        }
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 110)))     // …back before grace
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "display should revert to op(1), got \(tracker.state)")
        }
    }

    c.check("liveSliceOwner: an excursion's display does not own the open slice's clock") {
        // The "11m Studi" bug: during a grace-pending switch the display shows
        // the new task, but liveSliceStart still spans the OLD task's slice —
        // pairing them showed the old elapsed under the new name. The owner
        // must stay the outgoing task until commit, revert to it on return,
        // and move to the new task once the switch commits.
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        try expectEq(tracker.liveSliceOwner, .task(.op(1)))

        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))   // provisional
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "display should follow to op(2)")
        }
        try expectEq(tracker.liveSliceOwner, .task(.op(1)),
                     "pending switch: the open slice still belongs to op(1)")

        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 110)))     // revert
        try expectEq(tracker.liveSliceOwner, .task(.op(1)))

        tracker.handle(.focus(sig("Ghostty", "Investment", at: 200)))   // pending again
        tracker.handle(.input(t(265)))   // held past the 60 s slice floor → commits
        try expectEq(tracker.liveSliceOwner, .task(.op(2)),
                     "committed switch: the new task owns the slice")
    }

    c.check("pendingSwitchSince/graceEndsAt expose the provisional window, then clear on commit") {
        // The timeline hatches [pendingSwitchSince, graceEndsAt] as the still-
        // undecided tail of the live slice. It must be non-nil exactly while a
        // work switch is provisional, and clear the moment it commits.
        let (tracker, attributor) = makeTracker()   // default grace 30 → sliceFloor 60
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        try expect(tracker.pendingSwitchSince == nil, "a settled task has no provisional window")
        try expect(tracker.graceEndsAt == nil)

        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))   // provisional switch
        try expectEq(tracker.pendingSwitchSince, t(100),
                     "the provisional run begins at the switch moment")
        try expectEq(tracker.graceEndsAt, t(160),
                     "commit deadline is since + sliceFloor (max(grace 30, 60) = 60)")

        tracker.handle(.input(t(165)))   // held past the floor → commits
        try expect(tracker.pendingSwitchSince == nil,
                   "once the switch commits, nothing is undecided — the hatch clears")
        try expect(tracker.graceEndsAt == nil)
    }

    c.check("a reverted sub-grace excursion clears the provisional window") {
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))   // provisional
        try expectEq(tracker.pendingSwitchSince, t(100))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 110)))     // back within grace → revert
        try expect(tracker.pendingSwitchSince == nil,
                   "reverting the excursion un-hatches: it was never a real switch")
    }

    c.check("graceEndsAt tracks a non-default Switch Buffer via sliceFloor") {
        var config = TrackerConfig()
        config.switchGraceSeconds = 90   // sliceFloor = max(90, 60) = 90
        let (tracker, attributor) = makeTracker(config: config)
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))   // provisional
        try expectEq(tracker.graceEndsAt, t(190),
                     "the hatch's commit deadline follows the user's Switch Buffer")
    }

    c.check("a pending non-work stop is not a hatched task switch") {
        // A doNotTrack pend is a provisional STOP, not a task the timeline
        // draws — there is nothing to hatch, so the projection stays nil.
        let (tracker, attributor) = makeTracker()
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Steam", "Library", at: 30)))   // pending non-work stop
        try expect(tracker.pendingSwitchSince == nil,
                   "a pending non-work STOP is not an undecided task switch")
        try expect(tracker.graceEndsAt == nil)
    }

    c.check("sustained switch commits and grace-period time goes to the new task") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 120)))  // pending
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 160)))  // commits (40 s)
        tracker.stop(at: t(300))

        try expectEq(sessions.count, 2)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[1].task, .op(2))
        try expectEq(sessions[1].start, t(120), "grace-period minutes belong to the new task")
        try expectEq(sessions[1].end, t(300))
    }

    c.check("switch is instant; task-changed notification damps until held") {
        let (tracker, attributor) = makeTracker()
        var prompts: [TrackerPrompt] = []
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "switch must be instant, got \(tracker.state)")
        }
        try expect(!prompts.contains { $0 == .taskChanged(to: .task(.op(2))) },
                   "notification must not fire at the moment of switch")
        tracker.handle(.input(t(140)))   // 40 s in: under the one-minute floor, still quiet
        try expect(!prompts.contains { $0 == .taskChanged(to: .task(.op(2))) })
        tracker.handle(.input(t(165)))   // held past the minute floor: fires once
        try expect(prompts.contains { $0 == .taskChanged(to: .task(.op(2))) },
                   "notification fires once the switch has held a full minute")
    }

    c.check("idle stop resumes from a confident surface; manual stop does not") {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 600
        let (tracker, attributor) = makeTracker(config: config)
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(40)))
        tracker.handle(.input(t(700)))   // idle stop, trimmed to t(40)
        try expectEq(tracker.state, .stopped)
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 710)))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "primed surface must resume after idle stop, got \(tracker.state)")
        }
        tracker.stop(at: t(720))         // manual
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 730)))
        try expectEq(tracker.state, .stopped, "manual stop must be respected")
    }

    c.check("Martin's scenario: review-assigned surfaces, switch via typing") {
        // Both Ghostty windows primed via the REVIEW path (assign, not confirm),
        // tracking starts by auto-resume, then move to the other window and
        // type: sensor-style input events with slightly lagging dates.
        let (tracker, attributor) = makeTracker()
        attributor.assign(sig("Ghostty", "andeyeTT", at: 0), target: .task(.op(1)))
        attributor.assign(sig("Ghostty", "scratch", at: 0), target: .task(.op(2)))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        guard case .tracking(.task(.op(1)), let c1) = tracker.state, c1 >= 0.9 else {
            throw CheckFailure(description: "assign must prime like confirm, got \(tracker.state)")
        }
        tracker.handle(.focus(sig("Ghostty", "scratch", at: 60)))   // move to scratch
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "moving to scratch must switch instantly, got \(tracker.state)")
        }
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 70)))  // and straight back
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "returning must switch back instantly, got \(tracker.state)")
        }
    }

    c.check("call end prompts with call segments") {
        let (tracker, _) = makeTracker()
        var prompts: [TrackerPrompt] = []
        tracker.onPrompt = { prompts.append($0) }

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.microphone(active: true, at: t(30)))
        tracker.handle(.focus(sig("FaceTime", "Call", at: 30)))   // unknown -> uncertain
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 90)))
        tracker.handle(.microphone(active: false, at: t(95)))

        guard case .callEnded(let segments)? = prompts.last else {
            throw CheckFailure(description: "expected callEnded, got \(prompts)")
        }
        try expectEq(segments.count, 1)
        try expectEq(segments[0].app, "FaceTime")
    }

    c.check("commitLive journals the elapsed slice, resumes the same task, resets liveSliceStart") {
        // Materialise the live slice into a real journalled slice without
        // stopping the clock: the elapsed time commits as op(1), tracking keeps
        // running on op(1) from the commit moment, and liveSliceStart snaps to it.
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        try expectEq(tracker.liveSliceStart, t(0), "live slice starts at the open visit")
        tracker.commitLive(at: t(120))

        // The 120 s already on op(1) is journalled now…
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(120))
        // …and the clock keeps running on the SAME task from the commit moment.
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "commitLive must keep tracking op(1), got \(tracker.state)")
        }
        try expectEq(tracker.liveSliceStart, t(120),
                     "liveSliceStart resets to the commit moment (fresh run)")

        tracker.stop(at: t(180))
        try expectEq(sessions.count, 2, "the resumed run flushes as a second op(1) slice")
        try expectEq(sessions[1].start, t(120))
        try expectEq(sessions[1].end, t(180))
    }

    c.check("relabelCurrentSession re-tags every accumulated span, not just the future") {
        // Correct a mis-attributed RUNNING session: the elapsed (already-closed)
        // span re-attributes to the new task too, so the whole slice journals as
        // op(2) — without resetting the clock.
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 60)))  // closes the first span as op(1)
        tracker.relabelCurrentSession(to: .op(2))                    // re-tag elapsed + future
        guard case .tracking(.task(.op(2)), let cert) = tracker.state, cert >= 0.9 else {
            throw CheckFailure(description: "relabel must hold op(2) at confirmed certainty, got \(tracker.state)")
        }
        tracker.stop(at: t(180))

        try expect(!sessions.contains { $0.task == .op(1) },
                   "the elapsed time must re-attribute, leaving no op(1) slice")
        try expectEq(sessions.filter { $0.task == .op(2) }.count, 1, "one continuous op(2) slice")
        try expectEq(sessions.first?.start, t(0))
        try expectEq(sessions.first?.end, t(180))
    }

    c.check("backdateSessionStart extends the live slice earlier with a synthetic span") {
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(100))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 100)))
        try expectEq(tracker.liveSliceStart, t(100))
        tracker.backdateSessionStart(to: t(40))                      // drag the slice back
        try expectEq(tracker.liveSliceStart, t(40),
                     "a synthetic span covers the gap so the slice spans the whole stretch")
        // Backdating later than the current earliest is a no-op (guarded).
        tracker.backdateSessionStart(to: t(200))
        try expectEq(tracker.liveSliceStart, t(40), "a later backdate must not move the start forward")
    }

    c.check("adjustCurrentStart clamps to the previous closed span's end") {
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 50)))  // closes a span ending at t(50)
        // The open visit started at t(50); dragging it back past the closed span
        // is clamped so the visits cannot overlap.
        tracker.adjustCurrentStart(to: t(30))
        try expectEq(tracker.liveSliceStart, t(0),
                     "the closed span still starts at t(0); the clamp only bounds the open visit")
        // Dragging the open visit FORWARD within the slice is honoured.
        tracker.adjustCurrentStart(to: t(55))
        try expectEq(tracker.liveSliceStart, t(0))
    }


    c.check("manual start after a stop bills from the START tap, never from stopped-time focus changes (B1)") {
        let (tracker, _) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.stop(at: t(600))
        // While STOPPED the user changes windows at t+700…
        tracker.handle(.focus(sig("Ghostty", "somewhere else", at: 700)))
        // …and starts a new task at t+1900 (20 min later).
        tracker.start(task: .op(2), at: t(1900))
        tracker.handle(.input(t(2500)))
        tracker.stop(at: t(2500))
        let op2 = sessions.filter { $0.task == .op(2) }
        try expectEq(op2.count, 1)
        try expectEq(op2[0].start, t(1900),
                     "accrual begins at the tap — 20 min of stopped time must NOT bill")
        try expectEq(op2[0].end, t(2500))
    }

    c.check("mic-off reopens the span: same-window work after a call keeps accruing (B2)") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.microphone(active: true, at: t(60)))
        tracker.handle(.microphone(active: false, at: t(300)))
        // NO focus change after the call — the user keeps working in the
        // same window for 10 more minutes, then stops.
        tracker.handle(.input(t(600)))
        tracker.stop(at: t(900))
        let total = sessions.filter { $0.task == .op(1) }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        try expectEq(total, 900,
                     "the post-call stretch accrues without waiting for a window change")
    }

    c.check("wake with the clock stepped BACK across sleep never passes the grace window (C8)") {
        let (tracker, attributor) = makeTracker(config: {
            var cfg = TrackerConfig(); cfg.sleepGraceSeconds = 300; return cfg
        }())
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(500)))
        tracker.handle(.willSleep(t(600)))
        // DST fall-back / NTP: the wall clock at wake reads EARLIER than at
        // sleep. A negative interval passed `<= grace` and attributed the
        // whole multi-hour sleep to the task.
        tracker.handle(.didWake(t(-3000)))
        tracker.stop(at: t(700))
        let total = sessions.filter { $0.task == .op(1) }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        try expect(total <= 600, "no sleep-spanning attribution on a backward clock (got \(total))")
    }

    c.check("non-work grace time never bills to the work task, even across non-work window changes (B4)") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.handle(.input(t(500)))                                 // stay under the idle threshold
        tracker.handle(.focus(sig("Steam", "Library", at: 1000)))      // pend non-work at t1000
        tracker.handle(.focus(sig("Steam", "Store page", at: 1015)))   // non-work window CHANGE mid-grace
        tracker.handle(.input(t(1040)))                                // grace (30s) elapsed → stop commits
        let work = sessions.filter { $0.task == .op(1) }
        try expectEq(work.count, 1)
        try expectEq(work[0].end, t(1000),
                     "the work slice ends at the PEND moment — no Steam time on the client")
    }

    c.check("reevaluate re-tags the open spans and live target when a pin moves the target") {
        // A pin added mid-session must take effect immediately, not only on the
        // next focus change — reevaluate re-attributes the open spans and lifts
        // the live certainty/target to the pinned task.
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        // User pins this surface to op(2), then asks the tracker to re-evaluate.
        attributor.upsert(Pin(rule: .components(PinScope(kind: .app, prefix: ["Ghostty"])),
                              task: .op(2)))
        tracker.reevaluate()
        guard case .tracking(.task(.op(2)), let cert) = tracker.state, cert >= 0.99 else {
            throw CheckFailure(description: "reevaluate must follow the pin to op(2) at 1.0, got \(tracker.state)")
        }
    }

    c.check("away mode holds the session open across focus changes, then resumes and switches normally") {
        let (tracker, attributor) = makeTracker()
        attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
        tracker.away = true
        // While away, focus changes are ignored: the pinned task is held.
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 30)))
        tracker.handle(.input(t(60)))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "away must hold op(1) through a focus change, got \(tracker.state)")
        }
        // Clear away: the session is still op(1), and a real switch now lands.
        tracker.away = false
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "clearing away must leave op(1) running, got \(tracker.state)")
        }
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 90)))
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "a switch after away clears must follow normally, got \(tracker.state)")
        }
    }

    // MARK: - Async email capture: retroactive enrichment (2026-07-03 fix)

    c.check("focusEnrichment re-attributes the OPEN span when the surface is still current") {
        let (tracker, attributor) = makeTracker()
        // A learned domain rule that the bare (correspondent-less) signal
        // can't match yet — exactly the state RC1 left every live signal in.
        attributor.emailRules = [EmailRule(level: .correspondentDomain, value: "example.com",
                                           target: .op(2))]
        let bare = sig("Google Chrome", "Inbox - Gmail", at: 0,
                       url: "https://mail.google.com/mail/u/0/#inbox/abc")

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(bare))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "before enrichment: no rule can match, got \(tracker.state)")
        }

        var enriched = bare
        enriched.correspondents = ["r.naismith@example.com"]
        tracker.handle(.focusEnrichment(enriched))

        guard case .tracking(.task(.op(2)), let certainty) = tracker.state else {
            throw CheckFailure(description: "enrichment should let the domain rule fire, got \(tracker.state)")
        }
        try expectClose(certainty, Attributor.inferredCeiling)
    }

    c.check("focusEnrichment for a surface that's no longer open is dropped") {
        let (tracker, attributor) = makeTracker()
        attributor.emailRules = [EmailRule(level: .correspondentDomain, value: "example.com",
                                           target: .op(2))]
        let emailSurface = sig("Google Chrome", "Inbox - Gmail", at: 0,
                               url: "https://mail.google.com/mail/u/0/#inbox/abc")

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(emailSurface))
        tracker.handle(.focus(sig("Ghostty", "Notes", at: 5)))   // moved on before the probe returned

        var stale = emailSurface
        stale.correspondents = ["r.naismith@example.com"]
        tracker.handle(.focusEnrichment(stale))

        guard case .tracking(let target, _) = tracker.state else {
            throw CheckFailure(description: "expected .tracking, got \(tracker.state)")
        }
        try expect(target != .task(.op(2)),
                   "a stale enrichment for an abandoned surface must never re-tag whatever is open now")
    }

    c.check("focusEnrichment on a subject-only capture (no correspondents) still merges") {
        let (tracker, attributor) = makeTracker()
        attributor.emailRules = [EmailRule(level: .subject, value: "insurance renewals",
                                           target: .op(2))]
        let bare = sig("Google Chrome", "Re: Insurance Renewals 2026 - Gmail", at: 0,
                       url: "https://mail.google.com/mail/u/0/#inbox/xyz")

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(bare))

        var enriched = bare
        enriched.emailSubject = "Re: Insurance Renewals 2026"
        tracker.handle(.focusEnrichment(enriched))

        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "a subject-only enrichment should let the subject rule fire, got \(tracker.state)")
        }
    }

    c.check("a partial second enrichment never erases what the first one learned") {
        let (tracker, _) = makeTracker()
        let bare = sig("Google Chrome", "Re: X - Gmail", at: 0,
                       url: "https://mail.google.com/mail/u/0/#inbox/xyz")
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(bare))

        var first = bare
        first.correspondents = ["r.naismith@example.com"]
        tracker.handle(.focusEnrichment(first))
        var second = bare
        second.emailSubject = "Re: X"   // subject-only: correspondents nil
        tracker.handle(.focusEnrichment(second))

        try expectEq(tracker.currentFocusSignal?.correspondents, ["r.naismith@example.com"],
                     "subject-only follow-up clobbered the learned correspondents")
        try expectEq(tracker.currentFocusSignal?.emailSubject, "Re: X")
    }

    c.check("a COMMENT PIN makes a sub-grace excursion its own slice; the same excursion unpinned stays folded") {
        // Martin, 2026-07-09: three quick test comments on three tasks all
        // collapsed into one slice on one task. A commented visit is work by
        // attestation — it must surface however short, despite the grace
        // fold-back, minute dominance and the switch buffer.
        func run(pinned: Bool) throws -> [Session] {
            let (tracker, attributor) = makeTracker()
            var sessions: [Session] = []
            tracker.onSession = { sessions.append($0) }
            attributor.confirm(sig("Ghostty", "andeyeTT", at: 0), task: .op(1))
            attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))
            tracker.start(task: .op(1), at: t(0))
            tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 0)))
            // 15 s excursion to op(2), well inside the 30 s grace…
            tracker.handle(.focus(sig("Ghostty", "Investment", at: 120)))
            if pinned {
                // …with a comment committed mid-visit (display = op(2)).
                tracker.pinCurrentVisit(target: .task(.op(2)), at: t(128))
            }
            // …then straight back: the excursion reverts.
            tracker.handle(.focus(sig("Ghostty", "andeyeTT", at: 135)))
            tracker.handle(.input(t(200)))
            tracker.stop(at: t(240))
            return sessions
        }
        let folded = try run(pinned: false)
        try expectEq(folded.filter { $0.task == .op(2) }.count, 0,
                     "unpinned sub-grace excursion must stay folded (windows only)")
        try expectEq(folded.filter { $0.task == .op(1) }.count, 1)

        let attested = try run(pinned: true)
        let excursion = attested.filter { $0.task == .op(2) }
        try expectEq(excursion.count, 1, "pinned excursion must surface as its own slice")
        try expect(excursion[0].end.timeIntervalSince(excursion[0].start) <= 20,
                   "the pinned slice covers just the short visit")
        try expect(excursion[0].certainty >= 0.95, "user-attested certainty floor")
        // The surrounding op(1) time still flushes, split around the pin.
        try expect(attested.filter { $0.task == .op(1) }
            .allSatisfy { $0.end <= excursion[0].start.addingTimeInterval(1)
                       || $0.start >= excursion[0].end.addingTimeInterval(-1) },
                   "dominant slices must not overlap the carved pinned slice")
    }
}

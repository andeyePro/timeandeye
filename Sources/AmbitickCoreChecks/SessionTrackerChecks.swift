import Foundation
import AmbitickCore

// MARK: - SessionTracker (plan task 8)

func sessionTrackerChecks(_ c: Checks) {
    // t(n) = n seconds after a minute-aligned base (1_750_000_080 = 29_166_668 × 60)
    let base = Date(timeIntervalSince1970: 1_750_000_080)
    func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "Ambitick", status: "Now"),
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
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 50)))   // op(1) dominates min 0
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 90)))   // > grace: switch commits
        tracker.stop(at: t(130))

        try expectEq(sessions.count, 2)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(60))
        try expectEq(sessions[1].task, .op(2))
        try expectEq(sessions[1].start, t(60))
        try expectEq(sessions[1].end, t(130))
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
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
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
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
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
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.input(t(50)))
        tracker.handle(.willSleep(t(120)))
        tracker.handle(.didWake(t(3000)))

        try expectEq(sessions.first?.end, t(50))
        try expectEq(prompts, [.resumeAfterIdle(stoppedAt: t(50))])
    }

    c.check("brief uncertain patch does not sink session certainty (weighted mean)") {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 3600   // scripted gaps must not read as idle
        let (tracker, attributor) = makeTracker(config: config)
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))      // 19 min at 0.95
        tracker.handle(.focus(sig("Mystery", "???", at: 1140)))        // 1 min uncertain
        tracker.stop(at: t(1200))

        try expectEq(sessions.count, 1)
        try expect(sessions[0].certainty >= 0.8,
                   "weighted certainty must clear the push threshold; got \(sessions[0].certainty)")
        try expect(sessions[0].certainty < 0.95, "but the uncertain minute must count")
    }

    c.check("OP page auto-starts from stopped (URL and PWA title); primed surface does not") {
        let (tracker, attributor) = makeTracker()
        // URL signal
        tracker.handle(.focus(sig("Chrome", "WP", at: 0,
                                  url: "https://op.example.com/work_packages/1")))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "URL signal must auto-start, got \(tracker.state)")
        }
        tracker.stop(at: t(10))
        // PWA title signal (id lives in the app name)
        tracker.handle(.focus(ActivitySignal(app: "#2: Investment | OpenProject",
                                             timestamp: t(20))))
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "title signal must auto-start, got \(tracker.state)")
        }
        tracker.stop(at: t(30))
        // primed surface must NOT restart a stopped timer
        attributor.confirm(sig("Ghostty", "Ambitick", at: 30), task: .op(1))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 40)))
        try expectEq(tracker.state, .stopped, "manual stop must be respected")
    }

    c.check("brief excursion to another task's window merges back (switch buffer)") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))  // 10 s excursion
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 110)))    // back within grace
        tracker.stop(at: t(180))

        try expectEq(sessions.count, 1, "excursion must merge, not split")
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(180))
        try expect(!prompts.contains { if case .taskChanged = $0 { return true }; return false },
                   "no task-changed prompt for a merged excursion")
    }

    c.check("sustained switch commits and grace-period time goes to the new task") {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 120)))  // pending
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 160)))  // commits (40 s)
        tracker.stop(at: t(300))

        try expectEq(sessions.count, 2)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[1].task, .op(2))
        try expectEq(sessions[1].start, t(120), "grace-period minutes belong to the new task")
        try expectEq(sessions[1].end, t(300))
    }

    c.check("pending switch commits on input ticks when the user stays put") {
        let (tracker, attributor) = makeTracker()
        var prompts: [TrackerPrompt] = []
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 100)))  // pending switch
        tracker.handle(.input(t(110)))                                  // within grace
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "must still track op(1) within grace, got \(tracker.state)")
        }
        tracker.handle(.input(t(140)))                                  // grace elapsed
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "input tick must commit the switch, got \(tracker.state)")
        }
        try expect(prompts.contains { $0 == .taskChanged(to: .task(.op(2))) })
    }

    c.check("idle stop resumes from a confident surface; manual stop does not") {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 600
        let (tracker, attributor) = makeTracker(config: config)
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.input(t(40)))
        tracker.handle(.input(t(700)))   // idle stop, trimmed to t(40)
        try expectEq(tracker.state, .stopped)
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 710)))
        guard case .tracking(.task(.op(1)), _) = tracker.state else {
            throw CheckFailure(description: "primed surface must resume after idle stop, got \(tracker.state)")
        }
        tracker.stop(at: t(720))         // manual
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 730)))
        try expectEq(tracker.state, .stopped, "manual stop must be respected")
    }

    c.check("Martin's scenario: review-assigned surfaces, switch via typing") {
        // Both Ghostty windows primed via the REVIEW path (assign, not confirm),
        // tracking starts by auto-resume, then move to the other window and
        // type: sensor-style input events with slightly lagging dates.
        let (tracker, attributor) = makeTracker()
        attributor.assign(sig("Ghostty", "Ambitick", at: 0), target: .task(.op(1)))
        attributor.assign(sig("Ghostty", "scratch", at: 0), target: .task(.op(2)))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        guard case .tracking(.task(.op(1)), let c1) = tracker.state, c1 >= 0.9 else {
            throw CheckFailure(description: "assign must prime like confirm, got \(tracker.state)")
        }
        tracker.handle(.focus(sig("Ghostty", "scratch", at: 60)))   // move to scratch
        // typing: input dates lag ~1s behind wall clock, every 2s
        var clock: TimeInterval = 62
        while clock < 100 {
            tracker.handle(.input(t(clock - 1)))
            clock += 2
        }
        guard case .tracking(.task(.op(2)), _) = tracker.state else {
            throw CheckFailure(description: "typing in scratch must commit the switch, got \(tracker.state)")
        }
    }

    c.check("call end prompts with call segments") {
        let (tracker, _) = makeTracker()
        var prompts: [TrackerPrompt] = []
        tracker.onPrompt = { prompts.append($0) }

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.microphone(active: true, at: t(30)))
        tracker.handle(.focus(sig("FaceTime", "Call", at: 30)))   // unknown -> uncertain
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 90)))
        tracker.handle(.microphone(active: false, at: t(95)))

        guard case .callEnded(let segments)? = prompts.last else {
            throw CheckFailure(description: "expected callEnded, got \(prompts)")
        }
        try expectEq(segments.count, 1)
        try expectEq(segments[0].app, "FaceTime")
    }
}

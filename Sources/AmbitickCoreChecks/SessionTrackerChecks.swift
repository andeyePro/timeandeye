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
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 70)))
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

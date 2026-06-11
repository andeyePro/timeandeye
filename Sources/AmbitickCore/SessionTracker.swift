import Foundation

public struct TrackerConfig: Equatable, Sendable {
    public var minSegmentSeconds: TimeInterval
    public var primeDwellSeconds: TimeInterval
    public var idleThresholdSeconds: TimeInterval
    public var uncertainBelow: Double
    public var nonWorkTracksLocally: Bool
    public var leisureTask: TaskRef?
    /// A detected task switch only commits after the new target has held
    /// focus this long; briefer excursions merge back into the current task.
    /// Direct OP-page signals and manual picks bypass the grace.
    public var switchGraceSeconds: TimeInterval

    public init(minSegmentSeconds: TimeInterval = 20,
                primeDwellSeconds: TimeInterval = 30,
                idleThresholdSeconds: TimeInterval = 600,
                uncertainBelow: Double = 0.6,
                nonWorkTracksLocally: Bool = false,
                leisureTask: TaskRef? = nil,
                switchGraceSeconds: TimeInterval = 30) {
        self.minSegmentSeconds = minSegmentSeconds
        self.primeDwellSeconds = primeDwellSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.uncertainBelow = uncertainBelow
        self.nonWorkTracksLocally = nonWorkTracksLocally
        self.leisureTask = leisureTask
        self.switchGraceSeconds = switchGraceSeconds
    }
}

public enum TrackerState: Equatable, Sendable {
    case stopped
    case tracking(Target, certainty: Double)
}

public enum TrackerPrompt: Equatable, Sendable {
    case resumeAfterIdle(stoppedAt: Date)
    case callEnded(segments: [ReviewSegment])
    case taskChanged(to: Target)
}

/// Event-driven state machine. Single-threaded by contract: callers (the app's
/// sensor loop, or checks) deliver events in timestamp order on one actor/queue.
public final class SessionTracker {
    public private(set) var state: TrackerState = .stopped {
        didSet { if state != oldValue { onState(state) } }
    }
    public var onSession: (Session) -> Void = { _ in }
    public var onReview: (ReviewSegment) -> Void = { _ in }
    public var onState: (TrackerState) -> Void = { _ in }
    public var onPrompt: (TrackerPrompt) -> Void = { _ in }
    /// Diagnostic narration of decisions (attribution best, pending switches,
    /// commits, auto-starts). Wired to the app's debug log.
    public var onDebug: (String) -> Void = { _ in }

    private let attributor: Attributor
    private let config: TrackerConfig
    private let tasks: () -> [WorkTask]

    private var spans: [FocusSpan] = []
    private var currentSignal: ActivitySignal?
    private var currentStart: Date?
    private var lastInput: Date?
    private var pendingReview: ReviewSegment?
    private var micActiveSince: Date?
    private var callSegments: [ReviewSegment] = []
    private var idleStoppedAt: Date?
    private var pendingSwitch: (target: Target, score: Double, since: Date)?
    /// Manual Stop is respected (only a near-certain OP signal restarts);
    /// idle/auto stops may resume from any confident surface.
    private var stoppedManually = false

    public init(attributor: Attributor, config: TrackerConfig = TrackerConfig(),
                tasks: @escaping () -> [WorkTask]) {
        self.attributor = attributor
        self.config = config
        self.tasks = tasks
    }

    // MARK: - Public controls

    public func start(task: TaskRef, at date: Date) {
        flushSessions(asOf: date)
        lastInput = date
        state = .tracking(.task(task), certainty: 1.0)
    }

    public func stop(at date: Date, manual: Bool = true) {
        pendingSwitch = nil
        stoppedManually = manual
        endCurrentSpan(at: date)
        flushSessions(asOf: date)
        state = .stopped
    }

    /// User picked a task (popover/prompt) for the surface currently in focus.
    /// This is the UI's confirm entry point: it teaches the attributor AND
    /// lifts the in-flight span to confirmed certainty.
    public func confirm(task: TaskRef, at date: Date) {
        pendingSwitch = nil
        if let signal = currentSignal {
            attributor.confirm(signal, task: task)
        }
        if case .tracking = state {
            state = .tracking(.task(task), certainty: 0.95)
        } else {
            start(task: task, at: date)
        }
    }

    public func handle(_ event: SensorEvent) {
        switch event {
        case .focus(let signal): handleFocus(signal)
        case .input(let date): handleInput(date)
        case .willSleep(let date): idleStop(asOf: min(lastInput ?? date, date), promptNow: false)
        case .didWake: promptResumeIfIdleStopped()
        case .microphone(let active, let at): handleMic(active: active, at: at)
        }
    }

    // MARK: - Event handling

    private func handleInput(_ date: Date) {
        evaluatePendingSwitch(at: date)
        defer { lastInput = max(lastInput ?? date, date) }
        guard case .tracking = state, let last = lastInput,
              date.timeIntervalSince(last) > config.idleThresholdSeconds else { return }
        idleStop(asOf: last, promptNow: true)
    }

    private func handleFocus(_ signal: ActivitySignal) {
        let now = signal.timestamp
        handleInput(now)   // a focus change counts as input; also runs the idle check
        if let prev = currentSignal, let start = currentStart {
            if now.timeIntervalSince(start) >= config.primeDwellSeconds {
                attributor.noteDwell(prev)
            }
            endCurrentSpan(at: now)
        }
        let attribution = attributor.attribute(signal, tasks: tasks(), now: now)
        currentSignal = signal
        currentStart = now
        onDebug("focus \(signal.app)|\(signal.windowTitle ?? "-") -> best \(String(describing: attribution.best)) state \(state)")

        switch state {
        case .stopped:
            // After a MANUAL stop only a direct OP-task-page signal (URL 0.99
            // / title 0.97) restarts. After idle/auto stops, any confident
            // surface (primed >= 0.95) resumes the clock too.
            let gate = stoppedManually ? 0.96 : 0.9
            if let best = attribution.best, best.score >= gate,
               case .task(let task) = best.target {
                lastInput = now
                state = .tracking(.task(task), certainty: best.score)
                onPrompt(.taskChanged(to: .task(task)))
            }
        case .tracking(let currentTarget, _):
            guard let best = attribution.best else {
                state = .tracking(currentTarget, certainty: 0)
                return
            }
            if best.score >= config.uncertainBelow, best.target != currentTarget {
                handleConfidentSwitch(to: best, from: currentTarget, at: now)
            } else if best.score >= config.uncertainBelow {
                pendingSwitch = nil   // back on the current task: excursion merged
                state = .tracking(best.target, certainty: best.score)
            } else {
                // Uncertain: stick with the last certain target, flag it.
                state = .tracking(currentTarget, certainty: best.score)
            }
        }
    }

    /// Switch-buffer: humans rarely land directly on the right window, so a
    /// confident switch only commits after holding `switchGraceSeconds`;
    /// direct OP-page signals (>= 0.96) commit immediately.
    private func handleConfidentSwitch(to best: Candidate, from currentTarget: Target,
                                       at now: Date) {
        if best.score >= 0.96 {
            commitSwitch(to: best.target, score: best.score, since: now,
                         from: currentTarget, at: now)
        } else if pendingSwitch?.target != best.target {
            pendingSwitch = (best.target, best.score, now)
            onDebug("pending switch -> \(best.target) score \(best.score) since \(now)")
        }
        // A matching pending switch commits via evaluatePendingSwitch (input
        // ticks), so staying put on the new surface still commits after grace.
    }

    /// Driven by every input tick — a pending switch must commit even when no
    /// further focus change ever arrives (the user just stays in the window).
    private func evaluatePendingSwitch(at date: Date) {
        guard let pending = pendingSwitch, case .tracking(let current, _) = state else { return }
        let held = date.timeIntervalSince(pending.since)
        guard held >= config.switchGraceSeconds else { return }
        onDebug("commit pending switch -> \(pending.target) after \(Int(held))s")
        commitSwitch(to: pending.target, score: pending.score, since: pending.since,
                     from: current, at: date)
    }

    private func commitSwitch(to target: Target, score: Double, since: Date,
                              from currentTarget: Target, at now: Date) {
        pendingSwitch = nil
        // Re-tag the grace-period spans: that time belonged to the new target.
        for i in spans.indices where spans[i].start >= since {
            spans[i].target = target
            spans[i].certainty = score
        }
        if target == .doNotTrack {
            if config.nonWorkTracksLocally, let leisure = config.leisureTask {
                if currentTarget != .task(leisure) {
                    state = .tracking(.task(leisure), certainty: score)
                    onPrompt(.taskChanged(to: .task(leisure)))
                }
            } else {
                currentSignal = nil
                currentStart = nil
                stop(at: now, manual: false)   // auto-stop: work surfaces may resume
            }
        } else {
            state = .tracking(target, certainty: score)
            onPrompt(.taskChanged(to: target))
        }
    }

    private func handleMic(active: Bool, at date: Date) {
        if active {
            micActiveSince = date
            callSegments = []
        } else if micActiveSince != nil {
            // Flush BEFORE clearing the flag so in-flight call segments are
            // collected; only segments that started during the call count.
            endCurrentSpan(at: date)
            flushPendingReview()
            micActiveSince = nil
            if !callSegments.isEmpty {
                onPrompt(.callEnded(segments: callSegments))
            }
            callSegments = []
        }
    }

    // MARK: - Spans, review queue, sessions

    private func endCurrentSpan(at end: Date) {
        defer { currentSignal = nil; currentStart = nil }
        guard let signal = currentSignal, let start = currentStart, end > start,
              case .tracking(let target, let certainty) = state else { return }
        spans.append(FocusSpan(target: target, certainty: certainty, signal: signal,
                               start: start, end: end))
        if certainty < config.uncertainBelow {
            queueReview(signal: signal, start: start, end: end)
        } else {
            flushPendingReview()
        }
    }

    private func queueReview(signal: ActivitySignal, start: Date, end: Date) {
        if var p = pendingReview, p.app == signal.app, p.windowTitle == signal.windowTitle,
           p.tabURL == signal.tabURL {
            p.end = end
            pendingReview = p
        } else {
            flushPendingReview()
            pendingReview = ReviewSegment(app: signal.app, windowTitle: signal.windowTitle,
                                          tabURL: signal.tabURL, start: start, end: end)
        }
    }

    private func flushPendingReview() {
        guard let p = pendingReview else { return }
        pendingReview = nil
        guard p.end.timeIntervalSince(p.start) >= config.minSegmentSeconds else { return }
        if let since = micActiveSince, p.start >= since { callSegments.append(p) }
        onReview(p)
    }

    private func idleStop(asOf date: Date, promptNow: Bool) {
        pendingSwitch = nil
        guard case .tracking = state else { return }
        if let start = currentStart, date > start {
            endCurrentSpan(at: date)
        } else {
            currentSignal = nil
            currentStart = nil
        }
        flushSessions(asOf: date)
        state = .stopped
        stoppedManually = false   // idle stop: confident surfaces may resume
        idleStoppedAt = date
        if promptNow { promptResumeIfIdleStopped() }
    }

    private func promptResumeIfIdleStopped() {
        guard let stoppedAt = idleStoppedAt else { return }
        idleStoppedAt = nil
        onPrompt(.resumeAfterIdle(stoppedAt: stoppedAt))
    }

    /// Resolve accumulated spans into dominant-minute sessions and emit them.
    private func flushSessions(asOf date: Date) {
        flushPendingReview()
        let clipped = spans.compactMap { span -> FocusSpan? in
            guard span.start < date else { return nil }
            var s = span
            s.end = min(s.end, date)
            return s
        }
        spans = []
        guard !clipped.isEmpty else { return }
        let overallEnd = clipped.map(\.end).max()!
        let overallStart = clipped.map(\.start).min()!
        let minutes = MinuteResolver.dominantPerMinute(clipped)

        var runs: [(target: Target, start: Date, end: Date)] = []
        for (i, minute) in minutes.enumerated() {
            let mStart = max(minute.minuteStart, overallStart)
            let mEnd = min(minute.minuteStart.addingTimeInterval(60), overallEnd)
            if var last = runs.last, last.target == minute.target, i > 0,
               minutes[i - 1].minuteStart.addingTimeInterval(60) >= minute.minuteStart {
                last.end = mEnd
                runs[runs.count - 1] = last
            } else {
                runs.append((minute.target, mStart, mEnd))
            }
        }
        for run in runs {
            guard case .task(let ref) = run.target else { continue }   // doNotTrack time is never a session
            // Duration-weighted certainty: a brief uncertain patch must not
            // sink a long confident session below the push threshold (min()
            // did exactly that and silently blocked OP pushes).
            var weighted = 0.0
            var totalDuration = 0.0
            for span in clipped where span.target == run.target
                && span.end > run.start && span.start < run.end {
                let d = min(span.end, run.end).timeIntervalSince(max(span.start, run.start))
                weighted += span.certainty * d
                totalDuration += d
            }
            let certainty = totalDuration > 0 ? weighted / totalDuration : 0
            let comment = commentText(for: run, in: clipped)
            onSession(Session(task: ref, start: run.start, end: run.end,
                              certainty: certainty, comment: comment))
        }
    }

    /// "App – title" of up to the 3 longest-held surfaces in the run.
    private func commentText(for run: (target: Target, start: Date, end: Date),
                             in spans: [FocusSpan]) -> String? {
        var durations: [String: TimeInterval] = [:]
        for s in spans where s.end > run.start && s.start < run.end {
            let label = [s.signal.app, s.signal.windowTitle].compactMap { $0 }
                .joined(separator: " – ")
            let overlap = min(s.end, run.end).timeIntervalSince(max(s.start, run.start))
            durations[label, default: 0] += overlap
        }
        let top = durations.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        return top.isEmpty ? nil : top.joined(separator: "; ")
    }
}

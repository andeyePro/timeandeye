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
    /// Every closed focus span, for the timeline's window-level detail strip.
    public var onSpanClosed: (FocusSpan) -> Void = { _ in }

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
    /// A confident switch is provisional during the grace window: the DISPLAY
    /// (trackerState) follows the new task instantly, but the journal slice
    /// only commits if the new task is held past grace. `from` is the task the
    /// open slice still belongs to; a return to it within grace reverts (the
    /// excursion becomes windows in that slice). doNotTrack uses this too, to
    /// damp non-work auto-stop.
    private var pendingSwitch: (target: Target, from: Target, since: Date, score: Double)?
    private var pendingNotify: (target: Target, since: Date)?
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
        pendingNotify = nil
        stoppedManually = manual
        endCurrentSpan(at: date)
        flushSessions(asOf: date)
        state = .stopped
    }

    /// Timeline edit of the live slice: move the current visit's start.
    /// Clamped so it cannot overlap the previous closed span.
    public func adjustCurrentStart(to date: Date) {
        guard case .tracking = state, currentStart != nil else { return }
        currentStart = max(date, spans.last?.end ?? date)
    }

    /// Extend the in-flight session to start at `date` (earlier than it began),
    /// claiming the gap for the current task — used when the user drags the
    /// live slice back to fold in a prior same-task slice. A synthetic span
    /// covers the gap so the flush spans the whole stretch; the real window
    /// detail still comes from the journal's span table.
    public func backdateSessionStart(to date: Date) {
        guard case .tracking(let target, let cert) = state else { return }
        let earliest = (spans.map(\.start) + [currentStart].compactMap { $0 }).min() ?? date
        guard date < earliest else { return }
        let signal = currentSignal ?? ActivitySignal(app: "(extended)", timestamp: date)
        spans.insert(FocusSpan(target: target, certainty: max(cert, 0.95),
                               signal: signal, start: date, end: earliest), at: 0)
    }

    /// Relabel the CURRENT in-flight session to `task`: re-tag every
    /// accumulated span (so the elapsed time re-attributes, not just the
    /// future), confirm the association, and hold the clock. Distinct from
    /// confirm/switch — used by the popover's "Change to" to correct a
    /// mis-attributed running session without resetting it.
    public func relabelCurrentSession(to task: TaskRef) {
        guard case .tracking = state else { return }
        pendingSwitch = nil
        pendingNotify = nil
        for i in spans.indices {
            spans[i].target = .task(task)
            spans[i].certainty = 0.95
        }
        if let signal = currentSignal {
            attributor.confirm(signal, task: task)
        }
        state = .tracking(.task(task), certainty: 0.95)
    }

    /// User picked a task (popover/prompt) for the surface currently in focus.
    /// This is the UI's confirm entry point: it teaches the attributor AND
    /// lifts the in-flight span to confirmed certainty.
    public func confirm(task: TaskRef, at date: Date) {
        pendingSwitch = nil
        pendingNotify = nil
        if let signal = currentSignal {
            attributor.confirm(signal, task: task)
        }
        if case .tracking = state {
            state = .tracking(.task(task), certainty: 0.95)
        } else {
            start(task: task, at: date)
        }
    }

    /// "I'm leaving my desk": pin the current task and keep tracking it,
    /// ignoring focus changes, idle, sleep and calls until cleared.
    public var away = false

    public func handle(_ event: SensorEvent) {
        if away {
            // Hold the current session open: ignore everything except noting
            // input time (so returning doesn't immediately idle-stop once away
            // is cleared). No span is closed, so the whole away stretch stays
            // on the pinned task.
            if case .input(let date) = event { lastInput = max(lastInput ?? date, date) }
            return
        }
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
        case .tracking(let displayTarget, _):
            guard let best = attribution.best else {
                state = .tracking(displayTarget, certainty: 0)
                return
            }
            if let p = pendingSwitch, p.target != .doNotTrack {
                // We're provisionally showing p.target; the open slice is p.from.
                if best.target == p.from {
                    revertPendingSwitch()                 // returned within grace
                } else if best.target == p.target {
                    state = .tracking(p.target, certainty: best.score)   // hold pending
                } else if best.score >= config.uncertainBelow {
                    commitPendingSwitch(at: now)          // a third task: lock in p.target…
                    handleConfidentSwitch(to: best, from: p.target, at: now)  // …then pend new
                } else {
                    state = .tracking(p.target, certainty: best.score)   // uncertain, hold
                }
            } else if best.score >= config.uncertainBelow, best.target != displayTarget {
                handleConfidentSwitch(to: best, from: displayTarget, at: now)
            } else if best.score >= config.uncertainBelow {
                state = .tracking(best.target, certainty: best.score)
            } else {
                // Uncertain: stick with the last certain target, flag it.
                state = .tracking(displayTarget, certainty: best.score)
            }
        }
    }

    /// A confident switch: the display follows instantly, but the journal slice
    /// is held provisional through the grace window. A direct OP-page signal
    /// (>= 0.96) is deliberate and commits at once.
    private func handleConfidentSwitch(to best: Candidate, from committed: Target,
                                       at now: Date) {
        if best.target == .doNotTrack {
            if pendingSwitch?.target != best.target {
                pendingSwitch = (best.target, committed, now, best.score)
                onDebug("pending non-work stop since \(now)")
            }
            return
        }
        if best.score >= 0.96 {
            commitSwitch(to: best.target, score: best.score, at: now)   // deliberate
            return
        }
        pendingSwitch = (best.target, committed, now, best.score)
        pendingNotify = (best.target, now)
        state = .tracking(best.target, certainty: best.score)   // instant display
        onDebug("pending switch \(committed) -> \(best.target) since \(now)")
    }

    /// Grace elapsed with the new task still held: commit it. Flush the old
    /// task's slice up to the switch moment; the held spans continue as the new
    /// task's slice.
    private func commitPendingSwitch(at date: Date) {
        guard let p = pendingSwitch, p.target != .doNotTrack else { return }
        let signal = currentSignal
        endCurrentSpan(at: date)                 // close the in-flight (new-task) span
        let held = spans.filter { $0.start >= p.since }
        spans = spans.filter { $0.start < p.since }
        flushSessions(asOf: p.since)             // old task's slice, ending at the switch
        spans = held                             // new task's spans carry on
        currentSignal = signal                   // resume accumulating the new task
        currentStart = date
        pendingSwitch = nil
        onDebug("committed switch -> \(p.target) after grace")
    }

    /// Returned to the prior task within grace: the excursion was not a real
    /// switch. Re-tag its spans to the prior task (they become windows in that
    /// slice) and restore the display.
    private func revertPendingSwitch() {
        guard let p = pendingSwitch else { return }
        for i in spans.indices where spans[i].start >= p.since {
            spans[i].target = p.from
        }
        pendingSwitch = nil
        pendingNotify = nil
        if case .task = p.from { state = .tracking(p.from, certainty: 0.95) }
        onDebug("reverted excursion -> \(p.from) (kept as windows)")
    }

    /// Driven by every input tick: commits a held switch / non-work stop and
    /// fires the damped task-changed notification once a switch has held.
    private func evaluatePendingSwitch(at date: Date) {
        if let pending = pendingSwitch, case .tracking = state,
           date.timeIntervalSince(pending.since) >= config.switchGraceSeconds {
            if pending.target == .doNotTrack {
                commitSwitch(to: .doNotTrack, score: pending.score, at: date)
            } else {
                commitPendingSwitch(at: date)
            }
        }
        if let notify = pendingNotify, case .tracking(let current, _) = state,
           current == notify.target,
           date.timeIntervalSince(notify.since) >= config.switchGraceSeconds {
            pendingNotify = nil
            onPrompt(.taskChanged(to: notify.target))
        }
    }

    /// Commit a switch immediately (deliberate OP-page signal, or a grace-held
    /// doNotTrack stop): flush the finished task, then flip state.
    private func commitSwitch(to target: Target, score: Double, at now: Date) {
        let current: Target? = { if case .tracking(let t, _) = state { return t }; return nil }()
        pendingSwitch = nil
        if target == .doNotTrack {
            if config.nonWorkTracksLocally, let leisure = config.leisureTask {
                if current != .task(leisure) {
                    flushSessions(asOf: now)
                    state = .tracking(.task(leisure), certainty: score)
                    onPrompt(.taskChanged(to: .task(leisure)))
                }
            } else {
                currentSignal = nil
                currentStart = nil
                stop(at: now, manual: false)   // auto-stop: work surfaces may resume
            }
            return
        }
        flushSessions(asOf: now)
        state = .tracking(target, certainty: score)
        pendingNotify = (target, now)
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
        let span = FocusSpan(target: target, certainty: certainty, signal: signal,
                             start: start, end: end)
        spans.append(span)
        onSpanClosed(span)
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
        pendingNotify = nil
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
    /// Resolve all accumulated spans into dominant-minute sessions and emit
    /// them. Always emits everything: the in-flight session's time lives in
    /// `currentStart`/`currentSignal` (not yet in `spans`), so flushing on a
    /// switch journals the whole just-finished task with no leftover — holding
    /// back a "trailing run" used to strand the old task's last chunk and
    /// leave gaps / lose the slice.
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

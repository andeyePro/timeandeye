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
    /// A sleep shorter than this does NOT stop the clock: waking within the
    /// window continues the task that was being tracked (stepped away to read
    /// or to another device, not finished). A longer sleep stops as-of the
    /// moment activity ceased, like idle.
    public var sleepGraceSeconds: TimeInterval

    public init(minSegmentSeconds: TimeInterval = 20,
                primeDwellSeconds: TimeInterval = 30,
                idleThresholdSeconds: TimeInterval = 600,
                uncertainBelow: Double = 0.6,
                nonWorkTracksLocally: Bool = false,
                leisureTask: TaskRef? = nil,
                switchGraceSeconds: TimeInterval = 30,
                sleepGraceSeconds: TimeInterval = 60) {
        self.minSegmentSeconds = minSegmentSeconds
        self.primeDwellSeconds = primeDwellSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.uncertainBelow = uncertainBelow
        self.nonWorkTracksLocally = nonWorkTracksLocally
        self.leisureTask = leisureTask
        self.switchGraceSeconds = switchGraceSeconds
        self.sleepGraceSeconds = sleepGraceSeconds
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
    private var config: TrackerConfig
    private let tasks: () -> [WorkTask]

    /// C14: the idle threshold derives from pmset, which is a subprocess —
    /// too slow for the launch path. The controller starts with a cached
    /// value and applies the fresh reading here when it arrives; the
    /// threshold is a pure comparison bound, safe to move mid-tracking.
    public func setIdleThreshold(_ seconds: TimeInterval) {
        config.idleThresholdSeconds = seconds
    }

    /// The shortest run that may become its own journalled slice. Never below
    /// one displayed minute: a sub-minute slice shows as "0:00", which reads as
    /// a bug (an excursion you don't remember). So even with a short Switch
    /// Buffer, excursions under a minute fold back into the surrounding task
    /// instead of committing as their own slice.
    private var sliceFloor: TimeInterval { max(config.switchGraceSeconds, 60) }

    private var spans: [FocusSpan] = []
    private var currentSignal: ActivitySignal?

    /// The window/app currently in focus, so the controller can teach the
    /// attributor a durable association when the user picks "Change to X".
    public var currentFocusSignal: ActivitySignal? { currentSignal }
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
    /// What decided the CURRENT tracking target (journal provenance,
    /// 2026-07-10 why-panel follow-up). Refreshed whenever the target is
    /// (re)decided; deliberately HELD through uncertain patches, so a span
    /// that keeps the last certain target still tells the story of the
    /// decision that set it. Restored from `prePendingDecision` when a
    /// provisional switch reverts.
    private var currentDecision: SessionProvenance?
    private var prePendingDecision: SessionProvenance?
    private var pendingNotify: (target: Target, since: Date)?
    /// Manual Stop is respected (only a near-certain OP signal restarts);
    /// idle/auto stops may resume from any confident surface.
    private var stoppedManually = false
    /// What was tracking when the idle auto-stop fired, and when — the
    /// resume ladder's last rung (see the `.stopped` case in `handleFocus`).
    /// Cleared on any manual start/stop and once any rung resumes.
    private var idleStoppedTarget: Target?
    private var idleStoppedTargetAt: Date?
    /// Set on willSleep; resolved on didWake. The clock is NOT stopped while
    /// this is set — a quick wake continues, a long one stops retroactively.
    private var sleepingSince: Date?
    /// True between screenLocked and screenUnlocked: no window spans are opened
    /// while the Mac is locked (the window isn't really in use).
    private var screenLocked = false

    /// Start of the current continuous tracked slice: the earliest of all
    /// accumulated (not-yet-flushed) spans and the open visit. Unlike the
    /// app's per-visit `targetSince`, this is unaffected by sub-grace
    /// excursions that re-tag spans, so the timeline's live slice spans the
    /// whole ongoing stretch — exactly what a flush would journal — instead of
    /// jumping forward to the latest visit and leaving a phantom gap.
    public var liveSliceStart: Date? {
        (spans.map(\.start) + [currentStart].compactMap { $0 }).min()
    }

    /// The task the OPEN slice currently belongs to. During a grace-pending
    /// switch the DISPLAY (trackerState) follows the new task instantly, but
    /// the slice — and therefore `liveSliceStart`'s clock — still belongs to
    /// the task being left until the switch commits. The menu clock checks
    /// this so it never pairs the old slice's elapsed with the new task's
    /// name ("11m Studi" while the 11m is the andeye slice).
    public var liveSliceOwner: Target? {
        if let p = pendingSwitch { return p.from }
        if case .tracking(let target, _) = state { return target }
        return nil
    }

    /// Read-only projection of the provisional-switch window, for the timeline
    /// to hatch the still-uncommitted tail of the live slice. After a confident
    /// WORK switch the DISPLAY (trackerState) follows the new task instantly,
    /// but that run is "undecided" — held provisional — until it survives past
    /// `sliceFloor`: a return to the prior task before then reverts it (the
    /// excursion folds back as windows in the old slice). `pendingSwitchSince`
    /// is the instant that provisional run began; nil the moment nothing is
    /// undecided — a settled task owns its slice outright, and a *reverted* or
    /// *committed* switch clears it. A pending non-work STOP is deliberately
    /// excluded: it isn't a task the timeline draws, so there is nothing to
    /// hatch. Pure state read; nothing here mutates the tracker.
    public var pendingSwitchSince: Date? {
        guard let p = pendingSwitch, p.target != .doNotTrack else { return nil }
        return p.since
    }

    /// When the current provisional switch commits if the new task keeps focus:
    /// `pendingSwitchSince + sliceFloor` (the same threshold
    /// `evaluatePendingSwitch` commits a work switch at). nil when nothing is
    /// undecided. Past
    /// this instant the run journals to the new task on the next input tick, so
    /// the hatch caps here and solidifies.
    public var graceEndsAt: Date? {
        pendingSwitchSince.map { $0.addingTimeInterval(sliceFloor) }
    }

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
        // Accrual begins NOW (reviewer B1): while stopped, focus changes kept
        // updating currentStart, so starting at 10:30 after a 10:10 window
        // change billed 20 minutes of explicitly-stopped time to the new
        // task. Keep the signal's identity; restart its span here. (The
        // opposite hole — a nil signal accruing nothing while the clock
        // runs — is closed app-side: the sensor re-emits the current surface
        // on manual start.)
        if currentSignal != nil { currentStart = date }
        idleStoppedTarget = nil
        state = .tracking(.task(task), certainty: 1.0)
        currentDecision = .userAssigned
    }

    public func stop(at date: Date, manual: Bool = true) {
        pendingSwitch = nil
        pendingNotify = nil
        stoppedManually = manual
        if manual { idleStoppedTarget = nil }
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
                               signal: signal, start: date, end: earliest,
                               provenance: .userAssigned), at: 0)
    }

    /// The inverse of `backdateSessionStart`: pull the in-flight session's
    /// start FORWARD to `date`, dropping accumulated spans it no longer
    /// covers and trimming the one it lands inside. Exists so ⌘Z on a
    /// live-start extension can put the clock back exactly where it was —
    /// without it the undo group's journal inverses restore the folded rows
    /// but the live slice stays stretched over them (an overlap). No-op
    /// when stopped or when `date` wouldn't actually shrink the slice.
    public func trimSessionStart(to date: Date) {
        guard case .tracking = state else { return }
        spans.removeAll { $0.end <= date }
        for i in spans.indices where spans[i].start < date {
            spans[i].start = date
        }
        if let cs = currentStart, cs < date { currentStart = date }
    }

    /// Journal everything tracked so far on the current task up to `date` as a
    /// closed slice, then keep tracking the SAME task with a fresh run from
    /// `date`. Lets the timeline materialise the live slice into a real,
    /// editable slice without the user having to stop the clock.
    public func commitLive(at date: Date) {
        guard case .tracking = state else { return }
        let signal = currentSignal
        endCurrentSpan(at: date)
        flushSessions(asOf: date)
        currentSignal = signal      // resume the same surface…
        currentStart = date         // …as a fresh run from now
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
        // Pinned spans keep their attested target: a rapid pick-comment-pick
        // sequence (Martin's Time&I → Mon&I → Time&I test, 2026-07-09) is a
        // relabel each way, and re-tagging the commented middle stretch
        // erased its identity before the flush could surface it.
        for i in spans.indices where !isPinned(spans[i]) {
            spans[i].target = .task(task)
            spans[i].certainty = 0.95
            spans[i].provenance = .userAssigned
        }
        if let signal = currentSignal {
            attributor.confirm(signal, task: task, tasks: tasks())
        }
        state = .tracking(.task(task), certainty: 0.95)
        currentDecision = .userAssigned
    }

    /// Whether a span covers a comment-pinned moment for ITS OWN target —
    /// such spans are immune to relabel/reevaluate re-tagging.
    private func isPinned(_ span: FocusSpan) -> Bool {
        pins.contains { $0.target == span.target
            && $0.at >= span.start.addingTimeInterval(-1)
            && $0.at <= span.end.addingTimeInterval(1) }
    }

    /// The running clock as an attribution prior (Martin, 2026-07-10, his
    /// 228/240). While tracking a real task, its continuity is evidence for
    /// an ambiguous surface. During a provisional switch the prior backs the
    /// COMMITTED slice's task (`pendingSwitch.from`), not the display target
    /// — boosting a not-yet-committed guess would entrench it with its own
    /// echo. Stopped clocks carry no prior (the resume ladder owns that).
    private func liveContinuity(at now: Date) -> Attributor.Continuity? {
        guard case .tracking(let displayTarget, _) = state else { return nil }
        let committed = pendingSwitch.map(\.from) ?? displayTarget
        guard case .task = committed else { return nil }
        return .init(target: committed, lastActive: lastInput ?? currentStart ?? now)
    }

    /// Re-evaluate the current surface against the attributor WITHOUT splitting
    /// the open span — used when an association changes mid-session (e.g. the
    /// user just pinned this window) so the live certainty/target reflect it
    /// immediately instead of only on the next focus change. Re-tags the open
    /// spans if the pin moves the target.
    public func reevaluate() {
        guard case .tracking(let displayTarget, _) = state,
              let signal = currentSignal else { return }
        let attribution = attributor.attribute(signal, tasks: tasks(),
                                               now: signal.timestamp,
                                               continuity: liveContinuity(at: signal.timestamp))
        guard let best = attribution.best, best.score >= config.uncertainBelow else { return }
        if best.target != displayTarget {
            for i in spans.indices where !isPinned(spans[i]) {
                spans[i].target = best.target
                spans[i].provenance = attribution.provenance
            }
        }
        state = .tracking(best.target, certainty: best.score)
        // Same userAssigned-stickiness as the live path: an inferred
        // re-derivation that merely AGREES must not rewrite the story.
        if best.target != displayTarget
            || currentDecision?.sourceRaw != SessionProvenance.userAssigned.sourceRaw {
            currentDecision = attribution.provenance
        }
    }

    /// Apply a late-arriving correspondents/subject capture to the OPEN span
    /// (the async capture's retroactive half — 2026-07-03 diagnosis fix
    /// design). The probe that produced `signal` can return well after the
    /// user has moved on, so this is dropped (no-op) unless the enrichment's
    /// surface is STILL the one currently open; a stale enrichment must never
    /// re-tag whatever the user is looking at now. On a live match, merges
    /// the fields into `currentSignal` and re-derives attribution exactly as
    /// `reevaluate()` does, so a matching EmailRule/pin can re-attribute the
    /// span the moment the evidence arrives.
    private func applyEnrichment(_ signal: ActivitySignal) {
        guard let current = currentSignal,
              Surface(signal: current) == Surface(signal: signal) else {
            onDebug("dropped stale email enrichment for \(signal.app)")
            return
        }
        // Non-nil fields only: a later, partial enrichment for the same
        // surface (e.g. subject-only after a failed JS read) must not erase
        // what an earlier capture already learned.
        var merged = current
        if let correspondents = signal.correspondents { merged.correspondents = correspondents }
        if let subject = signal.emailSubject { merged.emailSubject = subject }
        currentSignal = merged
        reevaluate()
    }

    /// User picked a task (popover/prompt) for the surface currently in focus.
    /// This is the UI's confirm entry point: it teaches the attributor AND
    /// lifts the in-flight span to confirmed certainty.
    public func confirm(task: TaskRef, at date: Date) {
        pendingSwitch = nil
        pendingNotify = nil
        if let signal = currentSignal {
            attributor.confirm(signal, task: task, tasks: tasks())
        }
        if case .tracking = state {
            state = .tracking(.task(task), certainty: 0.95)
            currentDecision = .userAssigned
        } else {
            start(task: task, at: date)
        }
    }

    /// "I'm leaving my desk": pin the current task and keep tracking it,
    /// ignoring focus changes, idle, sleep and calls until cleared.
    public var away = false

    public func handle(_ event: SensorEvent) {
        // Lock state is resolved even while away: a locked screen must not keep
        // attributing the last window. Close the open span at lock and record
        // no window detail until unlock. The session itself keeps running (away
        // still pins it / idle handling unchanged) — only the bogus "you were
        // in Ghostty while the Mac was locked" detail is suppressed.
        switch event {
        case .screenLocked(let date): screenLocked = true; endCurrentSpan(at: date); return
        case .screenUnlocked: screenLocked = false; return
        default: break
        }
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
        case .focusEnrichment(let signal): applyEnrichment(signal)
        case .input(let date): handleInput(date)
        case .willSleep(let date): sleepingSince = date
        case .didWake(let date): handleWake(at: date)
        case .microphone(let active, let at): handleMic(active: active, at: at)
        case .screenLocked, .screenUnlocked: break   // handled above
        }
    }

    /// Resolve a sleep on wake. Within the grace window the clock simply
    /// carries on (the brief sleep counts as continued time on the same task).
    /// Beyond it, stop as-of the moment activity actually ceased and prompt to
    /// resume — the same retro-trim + prompt an idle stop does.
    private func handleWake(at date: Date) {
        guard let slept = sleepingSince else { promptResumeIfIdleStopped(); return }
        sleepingSince = nil
        // A NEGATIVE interval means the wall clock stepped back across the
        // sleep (DST fall-back, NTP correction): without this bound it
        // passes the <= grace test and a multi-hour sleep is attributed to
        // the last task and posted (reviewer C8, fires at least twice a
        // year). Treat it as beyond grace: stop as-of last real activity.
        let sleptFor = date.timeIntervalSince(slept)
        if case .tracking = state, sleptFor >= 0, sleptFor <= config.sleepGraceSeconds {
            lastInput = date
            onDebug("woke \(Int(sleptFor))s after sleep — within grace, continuing")
        } else {
            idleStop(asOf: min(lastInput ?? slept, slept), promptNow: true)
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
        if screenLocked { return }   // locked: don't open a window span
        let now = signal.timestamp
        handleInput(now)   // a focus change counts as input; also runs the idle check
        if let prev = currentSignal, let start = currentStart {
            if now.timeIntervalSince(start) >= config.primeDwellSeconds {
                attributor.noteDwell(prev, at: now)
            }
            endCurrentSpan(at: now)
        }
        let attribution = attributor.attribute(signal, tasks: tasks(), now: now,
                                               continuity: liveContinuity(at: now))
        currentSignal = signal
        currentStart = now
        onDebug("focus \(signal.app)|\(signal.windowTitle ?? "-") -> best \(String(describing: attribution.best)) state \(state)")
        if let boost = attributor.lastLiveBoost, let why = boost.reasoning {
            // Logged so the shared adjacency constants can be fitted from
            // corrections later — pair this with the decision that followed.
            onDebug("live-adjacency \(why) base \(boost.base) -> \(boost.certainty)")
        }

        switch state {
        case .stopped:
            // A MANUAL stop is fully sticky: nothing auto-resumes it until you
            // explicitly start again — so you can stop to fix the timeline
            // without the clock restarting under you and clobbering your edits.
            // Only idle/auto stops resume — and they resume on ANY returned
            // input, not just a confident surface (Martin, 2026-07-09: the
            // idle auto-stop left the app "stopped grey for no reason" until
            // a >=0.9 surface happened by). Resume ladder: a confident task
            // wins; else a merely-plausible one (>= uncertainBelow); else the
            // task that was tracking when idle stopped — at the CURRENT
            // signal's certainty, so a wrong guess lands in the review queue
            // rather than silently billing. The stale-target rung is bounded
            // to 30 min after the stop: resuming yesterday's task on this
            // morning's first click would just seed the queue with junk.
            guard !stoppedManually else { return }
            let idleContext = idleStoppedTargetAt.map { now.timeIntervalSince($0) <= 30 * 60 } ?? false
            if let best = attribution.best, best.score >= 0.9,
               case .task(let task) = best.target {
                lastInput = now
                idleStoppedTarget = nil
                state = .tracking(.task(task), certainty: best.score)
                currentDecision = attribution.provenance
                onPrompt(.taskChanged(to: .task(task)))
            } else if idleContext, let best = attribution.best,
                      best.score >= config.uncertainBelow,
                      case .task(let task) = best.target {
                lastInput = now
                idleStoppedTarget = nil
                state = .tracking(.task(task), certainty: best.score)
                currentDecision = attribution.provenance
                onPrompt(.taskChanged(to: .task(task)))
            } else if idleContext, let target = idleStoppedTarget, case .task = target {
                lastInput = now
                idleStoppedTarget = nil
                state = .tracking(target, certainty: attribution.best?.score ?? 0)
                currentDecision = .resumed
                onPrompt(.taskChanged(to: target))
            }
        case .tracking(let displayTarget, _):
            guard let best = attribution.best else {
                state = .tracking(displayTarget, certainty: 0)
                return
            }
            // A pending non-work stop is cancelled the instant a real task is
            // back in focus: returning to work within the grace window must not
            // let an earlier brief non-work flit auto-stop the clock (which left
            // an unfillable "pause" — the trailing time after a stop isn't a
            // between-slices gap, so click-to-fill couldn't reach it).
            if pendingSwitch?.target == .doNotTrack, best.score >= config.uncertainBelow,
               case .task = best.target {
                pendingSwitch = nil
                pendingNotify = nil
            }
            if let p = pendingSwitch, p.target != .doNotTrack {
                // We're provisionally showing p.target; the open slice is p.from.
                if best.target == p.from {
                    revertPendingSwitch(at: now)          // returned within grace
                } else if best.target == p.target {
                    state = .tracking(p.target, certainty: best.score)   // hold pending
                } else if best.score >= config.uncertainBelow {
                    // A third task arrived before the pending excursion matured
                    // past grace — so the pending one was itself just a brief
                    // flit, not a real switch. DON'T commit it: fold it back
                    // into the base task and pend the new target from that same
                    // base. (Committing it here made rapid window-flitting log a
                    // pile of sub-minute slices on whatever the ranker guessed.)
                    let base = p.from
                    revertPendingSwitch(at: now)
                    handleConfidentSwitch(to: best, from: base, at: now,
                                          provenance: attribution.provenance)
                } else {
                    state = .tracking(p.target, certainty: best.score)   // uncertain, hold
                }
            } else if best.score >= config.uncertainBelow, best.target != displayTarget {
                handleConfidentSwitch(to: best, from: displayTarget, at: now,
                                      provenance: attribution.provenance)
            } else if best.score >= config.uncertainBelow {
                state = .tracking(best.target, certainty: best.score)
                // Same target re-decided by inference: the user's own word
                // (start/confirm/relabel) stays the story — an agreeing
                // ranker must not overwrite "you assigned it".
                if currentDecision?.sourceRaw != SessionProvenance.userAssigned.sourceRaw {
                    currentDecision = attribution.provenance
                }
            } else {
                // Uncertain: stick with the last certain target, flag it.
                state = .tracking(displayTarget, certainty: best.score)
            }
        }
    }

    /// A confident switch: the display follows instantly, but the journal slice
    /// is held provisional through the grace window. EVERY attribution-driven
    /// switch — including a 1.0 pin — respects the buffer, so flitting THROUGH a
    /// pinned window folds back into the base task instead of instant-committing
    /// and fragmenting the timeline. (Only a held-past-buffer stay commits.
    /// Manual picks go through confirm()/start(), which bypass this entirely.)
    private func handleConfidentSwitch(to best: Candidate, from committed: Target,
                                       at now: Date,
                                       provenance: SessionProvenance? = nil) {
        if best.target == .doNotTrack {
            if pendingSwitch?.target != best.target {
                pendingSwitch = (best.target, committed, now, best.score)
                onDebug("pending non-work stop since \(now)")
            }
            return
        }
        pendingSwitch = (best.target, committed, now, best.score)
        pendingNotify = (best.target, now)
        prePendingDecision = currentDecision     // restored if the pend reverts
        currentDecision = provenance
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
        prePendingDecision = nil                 // the switch stands; no revert story
        onDebug("committed switch -> \(p.target) after grace")
    }

    /// Returned to the prior task within grace: the excursion was not a real
    /// switch. Re-tag its spans to the prior task (they become windows in that
    /// slice) and restore the display. UNLESS the excursion was PINNED (a
    /// comment was committed during it — Martin, 2026-07-09: a commented
    /// visit is work by attestation, however short): a pinned excursion is
    /// journalled RIGHT NOW as its own slice — waiting for the eventual
    /// flush left the timeline showing nothing where the user just
    /// commented (his 02:40 test: the pin fired, the slice appeared only
    /// at the next flush, which hadn't come when he looked). The emitted
    /// interval is remembered and carved out of the eventual dominant run.
    private func revertPendingSwitch(at date: Date = Date()) {
        guard let p = pendingSwitch else { return }
        let pinned = pins.contains { $0.target == p.target && $0.at >= p.since }
        if pinned, case .task(let ref) = p.target {
            let end = max(date, p.since.addingTimeInterval(1))
            onSession(Session(task: ref, start: p.since, end: end,
                              certainty: 0.95, comment: nil,
                              provenance: .init(source: .pin)))
            carvedIntervals.append((p.since, end))
            pins.removeAll { $0.target == p.target && $0.at >= p.since }
        }
        for i in spans.indices where spans[i].start >= p.since {
            spans[i].target = p.from
            spans[i].provenance = prePendingDecision
        }
        pendingSwitch = nil
        pendingNotify = nil
        currentDecision = prePendingDecision
        prePendingDecision = nil
        if case .task = p.from { state = .tracking(p.from, certainty: 0.95) }
        onDebug(pinned ? "reverted excursion -> \(p.from) (PINNED: slice journalled now)"
                       : "reverted excursion -> \(p.from) (kept as windows)")
    }

    /// Intervals already emitted as pinned mini-slices — the eventual
    /// dominant flush must not bill them again.
    private var carvedIntervals: [(start: Date, end: Date)] = []

    // MARK: - Comment pins

    /// Visits attested by a committed comment: (display target, moment). The
    /// flush surfaces each pinned visit as its OWN slice — exempt from
    /// minute dominance, the switch buffer and the grace fold-back — because
    /// the user just told us that moment was real work on that task.
    private var pins: [(target: Target, at: Date)] = []

    /// The controller calls this when a comment is committed. `target` is
    /// what the popover DISPLAYS (during a grace-pending switch that is the
    /// pending task, which matches the spans being written right now).
    public func pinCurrentVisit(target: Target, at date: Date = Date()) {
        guard case .tracking = state, case .task = target else { return }
        // Close and reopen the in-flight span so the pinned moment is
        // guaranteed to sit inside a CLOSED span carrying today's target —
        // a later flush can always find it.
        let signal = currentSignal
        endCurrentSpan(at: date)
        currentSignal = signal
        currentStart = date
        pins.append((target, date))
    }

    /// Driven by every input tick: commits a held switch / non-work stop and
    /// fires the damped task-changed notification once a switch has held.
    private func evaluatePendingSwitch(at date: Date) {
        if let pending = pendingSwitch, case .tracking = state {
            if pending.target == .doNotTrack {
                // Non-work auto-stop keeps the user-set buffer: unchanged.
                if date.timeIntervalSince(pending.since) >= config.switchGraceSeconds {
                    commitSwitch(to: .doNotTrack, score: pending.score, at: date)
                }
            } else if date.timeIntervalSince(pending.since) >= sliceFloor {
                // A WORK switch only commits once held a full minute, so a
                // sub-minute excursion folds back instead of journalling a
                // "0:00" slice (the reported bug). Display already followed
                // instantly; only the commit waits.
                commitPendingSwitch(at: date)
            }
        }
        if let notify = pendingNotify, case .tracking(let current, _) = state,
           current == notify.target,
           date.timeIntervalSince(notify.since) >= sliceFloor {
            pendingNotify = nil
            onPrompt(.taskChanged(to: notify.target))
        }
    }

    /// Commit a switch immediately (deliberate OP-page signal, or a grace-held
    /// doNotTrack stop): flush the finished task, then flip state.
    private func commitSwitch(to target: Target, score: Double, at now: Date) {
        let current: Target? = { if case .tracking(let t, _) = state { return t }; return nil }()
        let graceStart = pendingSwitch?.since
        pendingSwitch = nil
        if target == .doNotTrack {
            // NOTHING in the non-work grace window may bill to the work task
            // (reviewer B4: changing Steam windows during the pend closed a
            // work-tagged span mid-grace, so up to switchGraceSeconds of games
            // billed to a client per occurrence). Close the work story at the
            // PEND moment and drop/clip the grace-window spans.
            let boundary = graceStart ?? now
            let liveSignal = currentSignal
            if let start = currentStart, start >= boundary {
                currentSignal = nil
                currentStart = nil
            } else if currentSignal != nil {
                endCurrentSpan(at: boundary)
            }
            spans.removeAll { $0.start >= boundary }
            for i in spans.indices where spans[i].end > boundary {
                spans[i].end = boundary
            }
            if config.nonWorkTracksLocally, let leisure = config.leisureTask {
                if current != .task(leisure) {
                    flushSessions(asOf: boundary)
                    state = .tracking(.task(leisure), certainty: score)
                    // Leisure time began at the pend, and the sensor won't
                    // re-emit an unchanged surface: resume the span from the
                    // boundary under the NEW (leisure) state.
                    currentSignal = liveSignal
                    currentStart = boundary
                    onPrompt(.taskChanged(to: .task(leisure)))
                }
            } else {
                stop(at: boundary, manual: false)   // auto-stop: work surfaces may resume
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
            // Capture the signal first: endCurrentSpan clears it, and the
            // sensor never re-emits an unchanged surface — without reopening
            // here, a user who keeps working in the same window after a call
            // accrues NOTHING until the next window change while the clock
            // runs (reviewer B2, unbounded loss for single-window work).
            let liveSignal = currentSignal
            endCurrentSpan(at: date)
            flushPendingReview()
            micActiveSince = nil
            if !callSegments.isEmpty {
                onPrompt(.callEnded(segments: callSegments))
            }
            callSegments = []
            if case .tracking = state, let liveSignal {
                currentSignal = liveSignal
                currentStart = date
            }
        }
    }

    // MARK: - Spans, review queue, sessions

    private func endCurrentSpan(at end: Date) {
        defer { currentSignal = nil; currentStart = nil }
        guard let signal = currentSignal, let start = currentStart, end > start,
              case .tracking(let target, let certainty) = state else { return }
        let span = FocusSpan(target: target, certainty: certainty, signal: signal,
                             start: start, end: end, provenance: currentDecision)
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
            // Evidence isn't part of the surface key, so an extension may
            // carry MORE of it than the slice that opened the row (the async
            // email capture races focus changes — see `focusEnrichment`).
            // Merge rather than keep-first, or the row would teach/offer
            // grains from whichever slice happened to capture least.
            p.mergeEmailEvidence(from: signal)
            pendingReview = p
        } else {
            flushPendingReview()
            pendingReview = ReviewSegment(app: signal.app, windowTitle: signal.windowTitle,
                                          tabURL: signal.tabURL,
                                          correspondents: signal.correspondents,
                                          emailSubject: signal.emailSubject,
                                          start: start, end: end)
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
        guard case .tracking(let target, _) = state else { return }
        idleStoppedTarget = target
        idleStoppedTargetAt = date
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

        var runs: [(target: Target, start: Date, end: Date, pinned: Bool)] = []
        for (i, minute) in minutes.enumerated() {
            let mStart = max(minute.minuteStart, overallStart)
            let mEnd = min(minute.minuteStart.addingTimeInterval(60), overallEnd)
            if var last = runs.last, last.target == minute.target, i > 0,
               minutes[i - 1].minuteStart.addingTimeInterval(60) >= minute.minuteStart {
                last.end = mEnd
                runs[runs.count - 1] = last
            } else {
                runs.append((minute.target, mStart, mEnd, false))
            }
        }

        // COMMENT PINS: each pinned visit becomes its own FORCED run — the
        // contiguous same-target span chain around the pin — carved OUT of
        // whatever dominant run covered that interval. A commented visit is
        // work by the user's own attestation, however short.
        var forced: [(target: Target, start: Date, end: Date, pinned: Bool)] = []
        var futurePins: [(target: Target, at: Date)] = []
        for pin in pins {
            guard pin.at <= date else { futurePins.append(pin); continue }
            guard var chain = clipped.first(where: { $0.target == pin.target
                && $0.start <= pin.at.addingTimeInterval(1)
                && $0.end >= pin.at.addingTimeInterval(-1) })
                .map({ (start: $0.start, end: $0.end) }) else { continue }
            var grew = true
            while grew {
                grew = false
                for s in clipped where s.target == pin.target {
                    if s.start <= chain.end.addingTimeInterval(1), s.end > chain.end {
                        chain.end = s.end; grew = true
                    }
                    if s.end >= chain.start.addingTimeInterval(-1), s.start < chain.start {
                        chain.start = s.start; grew = true
                    }
                }
            }
            if !forced.contains(where: { $0.target == pin.target
                && $0.start == chain.start && $0.end == chain.end }) {
                forced.append((pin.target, chain.start, chain.end, true))
            }
        }
        pins = futurePins
        for f in forced {
            // If a same-target run already overlaps the pinned chain — the
            // pin was on the DOMINANT task — adding a forced twin would
            // journal two overlapping slices of the same task (found via
            // Martin's 03:58 log walk, 2026-07-09: the base-task comment's
            // chain duplicated the base run and stole the note onto one
            // twin). Just exempt the covering run(s) from the length gate.
            var coveredByOwnRun = false
            for i in runs.indices where runs[i].target == f.target
                && runs[i].start < f.end && runs[i].end > f.start {
                runs[i].pinned = true
                coveredByOwnRun = true
            }
            if coveredByOwnRun { continue }
            var carved: [(target: Target, start: Date, end: Date, pinned: Bool)] = []
            for run in runs {
                if run.pinned {
                    carved.append(run)   // earlier pins pass through intact
                } else if run.end <= f.start || run.start >= f.end || run.target == f.target {
                    carved.append(run)
                } else {
                    if run.start < f.start { carved.append((run.target, run.start, f.start, false)) }
                    if run.end > f.end { carved.append((run.target, f.end, run.end, false)) }
                }
            }
            carved.append(f)
            runs = carved
        }
        // Intervals ALREADY journalled as pinned mini-slices at revert time:
        // subtract them from every run (they must not bill twice), and
        // forget the ones this flush has passed.
        for c in carvedIntervals where c.start < date {
            var trimmed: [(target: Target, start: Date, end: Date, pinned: Bool)] = []
            for run in runs {
                if run.end <= c.start || run.start >= c.end {
                    trimmed.append(run)
                } else {
                    if run.start < c.start { trimmed.append((run.target, run.start, c.start, run.pinned)) }
                    if run.end > c.end { trimmed.append((run.target, c.end, run.end, run.pinned)) }
                }
            }
            runs = trimmed
        }
        carvedIntervals.removeAll { $0.end <= date }
        runs.sort { $0.start < $1.start }

        for run in runs {
            guard case .task(let ref) = run.target else { continue }   // doNotTrack time is never a session
            // No sub-buffer slices: a run shorter than the Switch Buffer is a
            // flit, not work, and must never reach the timeline. The grace logic
            // stops most flits upstream; this catches the rest (e.g.
            // instant-commit pin switches that bypass grace). Kept at the buffer
            // (not the minute floor) so a genuinely-short first/last slice — the
            // task you started, then switched off 40 s later — is still kept.
            // Floor the run at the buffer, but NEVER above one displayed minute:
            // with a Switch Buffer set > 60s, a slice the user deliberately
            // started that ran 61–120s and was then switched off is WORK, not a
            // flit — dropping it (the old `>= switchGraceSeconds`) was silent
            // data loss. Default buffer (30s) is unchanged: min(30,60)=30.
            // PINNED runs are exempt: the comment is the user saying "this
            // moment was work" — no floor applies.
            guard run.pinned || run.end.timeIntervalSince(run.start)
                    >= min(config.switchGraceSeconds, 60) else { continue }
            // Duration-weighted certainty: a brief uncertain patch must not
            // sink a long confident session below the push threshold (min()
            // did exactly that and silently blocked OP pushes).
            var weighted = 0.0
            var totalDuration = 0.0
            var provenanceDurations: [SessionProvenance: TimeInterval] = [:]
            for span in clipped where span.target == run.target
                && span.end > run.start && span.start < run.end {
                let d = min(span.end, run.end).timeIntervalSince(max(span.start, run.start))
                weighted += span.certainty * d
                totalDuration += d
                if let p = span.provenance { provenanceDurations[p, default: 0] += d }
            }
            // A pinned run is user-attested work: floor its certainty at the
            // manual-confidence level whatever the attribution scored it.
            let certainty = max(totalDuration > 0 ? weighted / totalDuration : 0,
                                run.pinned ? 0.95 : 0)
            let comment = commentText(for: (run.target, run.start, run.end), in: clipped)
            // The slice's provenance is its DOMINANT decider by covered
            // duration (ties break on the raw name for determinism); a
            // pinned run is the user's own attestation whatever decided
            // the spans underneath.
            let provenance = run.pinned
                ? SessionProvenance(source: .pin)
                : provenanceDurations.max { a, b in
                      (a.value, b.key.sourceRaw) < (b.value, a.key.sourceRaw)
                  }?.key
            onSession(Session(task: ref, start: run.start, end: run.end,
                              certainty: certainty, comment: comment,
                              provenance: provenance))
        }
    }

    /// "App – title" of up to the 3 longest-held surfaces in the run.
    private func commentText(for run: (target: Target, start: Date, end: Date),
                             in spans: [FocusSpan]) -> String? {
        var durations: [String: TimeInterval] = [:]
        // Only the run's OWN spans feed its comment (reviewer B10): a
        // doNotTrack/other-task span inside a minute this task won could put
        // a personal window title into an OP/Xero time-entry comment.
        for s in spans where s.target == run.target
            && s.end > run.start && s.start < run.end {
            let label = [s.signal.app, s.signal.windowTitle].compactMap { $0 }
                .joined(separator: " – ")
            let overlap = min(s.end, run.end).timeIntervalSince(max(s.start, run.start))
            durations[label, default: 0] += overlap
        }
        let top = durations.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        return top.isEmpty ? nil : top.joined(separator: "; ")
    }
}

import Foundation
import AppKit
import Carbon.HIToolbox   // kVK_ANSI_L / cmdKey / shiftKey for the global Away hotkey
import AmbitickCore

/// Pure title/cadence logic, kept out of the controller so it is checkable.
public enum MenuTitle {
    /// 1 Hz for the first minute after a task change, then once per minute.
    public static func refreshInterval(sinceTaskChange: TimeInterval) -> TimeInterval {
        sinceTaskChange < 60 ? 1 : 60
    }

    /// Seconds only under a minute, whole minutes under an hour, then h+m —
    /// per-second precision is noise once the first minute has passed.
    public static func text(elapsed: TimeInterval, certainty: Double?,
                            showPercent: Bool) -> String {
        let total = Int(elapsed.rounded())
        let body: String
        if total < 60 {
            body = "\(total)s"
        } else if total < 3600 {
            body = "\(total / 60)m"
        } else {
            body = String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
        }
        if showPercent, let certainty {
            return "\(body) \(Int((certainty * 100).rounded()))%"
        }
        return body
    }

    /// Optional task tag after the time in the menu bar: the first `chars` of
    /// the task name, so a glance reads "21m Ambit" rather than just "21m".
    /// No ellipsis — the truncation is implicit and it saves a character.
    /// Empty name or chars <= 0 leaves the body alone.
    public static func withTaskName(_ name: String?, chars: Int, body: String) -> String {
        guard let name, chars > 0 else { return body }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        return "\(body) \(String(trimmed.prefix(chars)))"
    }

    /// Elapsed for the live clock. `liveSliceStart` (the tracker's contiguous
    /// slice start) is authoritative: it spans excursion windows that reverted
    /// back to the base task, which the per-visit banked+running figure misses —
    /// so without it the menu bar under-counts heavy flitting versus what flushes
    /// to OP. The banked+running fallback wins when there is no live slice (slice
    /// just committed: the tracker reset to `now` while the controller re-banked
    /// the committed time to keep the clock continuous), so take the larger.
    public static func displayedElapsed(liveSliceStart: Date?, bankedFallback: TimeInterval,
                                        running: TimeInterval, now: Date) -> TimeInterval {
        let fallback = bankedFallback + running
        guard let start = liveSliceStart else { return fallback }
        return max(now.timeIntervalSince(start), fallback)
    }

    /// Linear blend between the user's two gradient colours; grey when stopped.
    public static func colour(certainty: Double?, lowHex: String, highHex: String) -> NSColor {
        guard let certainty else { return .systemGray }
        let low = NSColor(hex: lowHex) ?? .systemRed
        let high = NSColor(hex: highHex) ?? .systemGreen
        let f = CGFloat(min(max(certainty, 0), 1))
        return NSColor(
            red: low.redComponent + (high.redComponent - low.redComponent) * f,
            green: low.greenComponent + (high.greenComponent - low.greenComponent) * f,
            blue: low.blueComponent + (high.blueComponent - low.blueComponent) * f,
            alpha: 1)
    }
}

public extension NSColor {
    /// Black on light backgrounds, white on dark — by perceived luminance.
    var readableTextColour: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent
            + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// URLSession-backed transport for the real OP instance.
public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// An idle/away stretch that defaulted to untracked, offered for one-tap claim.
public struct IdleGap: Equatable, Sendable {
    public var task: TaskRef
    public var from: Date
    public var to: Date
}

/// Owns the whole pipeline: sensors -> tracker -> journal -> sync, plus the
/// published state the SwiftUI layer renders.
@MainActor
public final class AppController: ObservableObject {
    @Published public private(set) var trackerState: TrackerState = .stopped
    @Published public private(set) var menuText = "–"
    /// Elapsed time only (no task name) for the popover, which shows the task as
    /// its headline — see refreshTitle.
    @Published public private(set) var elapsedText = "–"
    @Published public private(set) var menuColour = NSColor.systemGray
    @Published public private(set) var taskCache: [WorkTask] = []
    @Published public private(set) var pendingReview: [ReviewSegment] = []
    @Published public private(set) var activities: [OPTimeActivity] = []
    @Published public private(set) var lastPrompt: TrackerPrompt?
    /// An idle stretch that defaulted to "break" (untracked). A single tap in
    /// the popover claims it as the task you were on — no timeline needed. It
    /// survives auto-resume and stays offered for `idleBackfillWindowSeconds`.
    @Published public private(set) var pendingGap: IdleGap?
    @Published public private(set) var lastError: String?
    @Published public private(set) var journalSummary = ""
    @Published public private(set) var connectedAs: String?
    /// The speech-bubble note: replaces the auto comment on sessions closing
    /// while it is set; cleared when tracking stops.
    /// The speech-bubble note. NOT @Published: binding a TextField to a
    /// published var rebuilds the whole popover on every keystroke and steals
    /// focus ("can't type"). The popover edits a local copy and pushes here.
    public var manualNote = ""
    @Published public var settings: AmbitickSettings {
        didSet {
            try? settingsStore.save(settings)
            Notifier.enabled = settings.systemNotifications
            attributor.emailMatchOrder = settings.emailMatchOrder
            if oldValue.opBaseURL != settings.opBaseURL { rebuildClient() }
            // Local-task edits (rename / project / leisure / add / remove) flow
            // straight into the live cache so every list, the timeline and the
            // pie reflect them at once.
            if oldValue.localTasks != settings.localTasks { mergeLocalTasksIntoCache() }
        }
    }

    public let journal: any JournalStore
    private let attributor: Attributor
    private var tracker: SessionTracker!
    private let sensors = SensorHub()
    private let settingsStore: JSONFileStore<AmbitickSettings>
    private let learningStore: JSONFileStore<LearningStore>
    private let primedStore: JSONFileStore<[Surface: TaskRef]>
    private let pinsStore: JSONFileStore<[Pin]>
    private let emailRulesStore: JSONFileStore<[EmailRule]>
    private var client: OPClient?
    private var titleTimer: Timer?
    private var taskRefreshTimer: Timer?
    /// System-wide ⌘⇧L "Away" toggle (Carbon RegisterEventHotKey). The
    /// SwiftUI .keyboardShortcut in the popover only fires when Ambitick is
    /// key; this fires from any app. Installed in startUp, torn down on
    /// terminate/deinit (which unregisters the Carbon hotkey + handler).
    private var awayHotKey: GlobalHotKey?
    /// Dedicated, tight (~12 s) crash-safety checkpoint timer, gated to
    /// .tracking. Generous tolerance lets the OS coalesce the wakeup, so the
    /// extra cadence costs no measurable energy over the 60 s refresh timer.
    private var checkpointTimer: Timer?
    private var taskChangedAt = Date()
    private var currentTarget: Target?
    /// The task we were tracking immediately before the current one, held in
    /// memory so "revert" offers the task you actually just left — not the
    /// journal's most-recent-by-start closed slice, which could be a stray
    /// earlier minute (Martin saw it offer a 1-min "a university course" instead of
    /// the Ambitick he'd just switched away from, because that slice hadn't
    /// flushed yet during the switch grace).
    private var previousTask: TaskRef?
    /// Per-task session accumulators: each task banks its own visited time.
    /// Returning to a task resumes its clock; a task that holds focus past the
    /// grace ("takes over") ends every other task's session. Cleared on stop.
    private var bankedElapsed: [Target: TimeInterval] = [:]
    private var targetSince: Date?
    private var visitSolid = false

    public static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ambitick")
    }

    public init() {
        let dir = Self.supportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsStore = JSONFileStore<AmbitickSettings>(url: dir.appendingPathComponent("settings.json"))
        learningStore = JSONFileStore<LearningStore>(url: dir.appendingPathComponent("learning.json"))
        primedStore = JSONFileStore<[Surface: TaskRef]>(url: dir.appendingPathComponent("primed.json"))
        pinsStore = JSONFileStore<[Pin]>(url: dir.appendingPathComponent("pins.json"))
        emailRulesStore = JSONFileStore<[EmailRule]>(url: dir.appendingPathComponent("emailrules.json"))
        let loadedSettings = (try? settingsStore.load().flatMap { $0 })
            ?? AmbitickSettings(opBaseURL: "")
        settings = loadedSettings
        journal = (try? SQLiteJournalStore(path: dir.appendingPathComponent("journal.sqlite").path))
            ?? InMemoryJournalStore()

        let host = URL(string: loadedSettings.opBaseURL)?.host ?? ""
        let learning = (try? learningStore.load().flatMap { $0 }) ?? LearningStore()
        attributor = Attributor(instanceHost: host,
                                learning: learning,
                                ranker: TaskRanker(config: RankingConfig(statusOrder: loadedSettings.statusOrder)))
        if let primed = (try? primedStore.load()).flatMap({ $0 }) {
            attributor.primedSurfaces = primed
        }
        attributor.emailMatchOrder = loadedSettings.emailMatchOrder
        if let rules = (try? emailRulesStore.load()).flatMap({ $0 }) {
            attributor.emailRules = rules
        }
        if let pins = (try? pinsStore.load()).flatMap({ $0 }) {
            attributor.pins = pins
        } else {
            // Migrate legacy scope→task pins (pre-rule-engine) to component pins.
            // Self-terminating one-shot: once we save the migrated [Pin] back to
            // pins.json, the [Pin] decode above succeeds on every later launch, so
            // this else branch never runs again.
            let legacyStore = JSONFileStore<[PinScope: TaskRef]>(
                url: dir.appendingPathComponent("pins.json"))
            if let legacy = (try? legacyStore.load()).flatMap({ $0 }), !legacy.isEmpty {
                attributor.pins = legacy.map { Pin(rule: .components($0.key), task: $0.value) }
                try? pinsStore.save(attributor.pins)
            }
        }

        let leisure = loadedSettings.localTasks.first(where: \.isLeisure)
            .map { TaskRef.local($0.id) }
        let config = TrackerConfig(
            minSegmentSeconds: loadedSettings.minSegmentSeconds,
            primeDwellSeconds: loadedSettings.primeDwellSeconds,
            idleThresholdSeconds: PowerSettings.displaySleepSeconds() ?? 600,
            nonWorkTracksLocally: loadedSettings.trackLeisureLocally && leisure != nil,
            leisureTask: leisure,
            switchGraceSeconds: loadedSettings.switchGraceSeconds,
            sleepGraceSeconds: loadedSettings.sleepGraceSeconds)
        tracker = SessionTracker(attributor: attributor, config: config) { [weak self] in
            self?.taskCache ?? []
        }
        wireTracker()
        rebuildClient()
        taskCache = localWorkTasks()   // locals exist before OP ever connects
        applyJournalRecency()          // recency survives the relaunch
    }

    /// User-defined non-OP tasks rendered as first-class tasks.
    private func localWorkTasks() -> [WorkTask] {
        settings.localTasks.map {
            WorkTask(ref: .local($0.id), subject: $0.name, project: $0.projectName,
                     status: $0.isLeisure ? "Leisure" : "Open")
        }
    }

    /// Create (or reuse) a local task. `primeToCurrentSurface` is set ONLY by the
    /// genuine user-creation UI paths (Settings/Review): on a brand-new task it
    /// confirms the current frontmost surface to it so the live session
    /// attributes to the new task immediately, instead of staying on the
    /// previously-focused task until the user reassigns once. It must stay false
    /// for rename/merge/programmatic callers — they aren't a fresh user pick of
    /// "this surface is this task", and the same-name reuse path below returns
    /// before any priming so re-typing an existing name never re-primes.
    @discardableResult
    public func addLocalTask(name: String, isLeisure: Bool, project: String? = nil,
                            primeToCurrentSurface: Bool = false) -> TaskRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse an existing local task of the same name instead of duplicating.
        if let existing = settings.localTasks.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .local(existing.id)
        }
        let def = LocalTaskDef(name: trimmed, isLeisure: isLeisure, project: project)
        settings.localTasks.append(def)
        mergeLocalTasksIntoCache()
        registerUndo("add local task \(trimmed)") { [weak self] in
            self?.removeLocalTask(def.id, undoable: false)
        }
        // Genuine NEW creation from a user pick: bind the frontmost surface to it
        // now (confirm = soft 0.95 prime + learn) and lift the in-flight span,
        // the same way commitPin does, so attribution doesn't lag a focus cycle.
        if primeToCurrentSurface, let signal = tracker.currentFocusSignal {
            attributor.confirm(signal, task: .local(def.id))
            persistAssociations()
            tracker.reevaluate()
        }
        return .local(def.id)
    }

    /// Edit an existing local task in place (name / project / leisure). Keeps
    /// its id, so its history, colour and learned associations all carry over —
    /// only the display + grouping change (the local-task analogue of renaming
    /// a work package in OpenProject).
    public func updateLocalTask(_ id: UUID, name: String? = nil, project: String? = nil,
                                isLeisure: Bool? = nil) {
        guard let i = settings.localTasks.firstIndex(where: { $0.id == id }) else { return }
        if let name { settings.localTasks[i].name = name }
        if let project { settings.localTasks[i].project = project }
        if let isLeisure { settings.localTasks[i].isLeisure = isLeisure }
        mergeLocalTasksIntoCache()
    }

    /// Distinct local project names already in use, for offering as quick picks
    /// in the editor (free text is still allowed).
    public func localProjectNames() -> [String] {
        var seen: [String] = []
        for def in settings.localTasks where !seen.contains(def.projectName) {
            seen.append(def.projectName)
        }
        return seen
    }

    public func removeLocalTask(_ id: UUID, undoable: Bool = true) {
        if undoable, let def = settings.localTasks.first(where: { $0.id == id }) {
            registerUndo("remove local task \(def.name)") { [weak self] in
                self?.settings.localTasks.append(def)
                self?.mergeLocalTasksIntoCache()
            }
        }
        settings.localTasks.removeAll { $0.id == id }
        taskCache.removeAll { $0.ref == .local(id) }
    }

    /// Rebuild the local-task entries in the cache from settings so renames,
    /// project changes and removals all show through immediately — preserving
    /// each local task's recency (lastConfirmedAt lives only in the cache).
    private func mergeLocalTasksIntoCache() {
        var recency: [TaskRef: Date] = [:]
        for t in taskCache {
            if case .local = t.ref, let last = t.lastConfirmedAt { recency[t.ref] = last }
        }
        taskCache.removeAll { if case .local = $0.ref { return true }; return false }
        for var task in localWorkTasks() {
            task.lastConfirmedAt = recency[task.ref]
            taskCache.append(task)
        }
        applyJournalRecency()   // rebuilt locals keep their durable recency too
    }

    private func wireTracker() {
        tracker.onSession = { [weak self] session in
            guard let self else { return }
            var s = session
            // Consume the speech-bubble note HERE, when the slice it belongs to
            // is actually journalled — not on the display switch — so it
            // survives transient excursions and lands on the slice it was
            // written for, even when the slice commits after the grace delay.
            let note = self.manualNote
            // Route the note per the two toggles: 'comment to tracked time'
            // attaches it to the time entry (s.comment, pushed to OP); 'comment
            // to task' also posts it to the task's activity feed, where it is
            // far easier to find. The auto window-list comment is the fallback
            // for the time entry only when no manual note was written.
            s.comment = CommentRouting.timeEntryComment(
                note: note, autoCommentText: s.comment,
                autoCommentEnabled: self.settings.autoComment,
                toTrackedTime: self.settings.commentToTrackedTime)
            let taskNote = CommentRouting.taskComment(note: note,
                                                      toTask: self.settings.commentToTask)
            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.manualNote = ""
            }
            try? self.journal.save(s)
            if let taskNote, case .op(let wpID) = s.task {
                Task { await self.postTaskComment(wpID: wpID, note: taskNote) }
            }
            // Tracked time counts as recency: the task you just worked on
            // belongs at the top of every pick list.
            if let i = self.taskCache.firstIndex(where: { $0.ref == s.task }) {
                self.taskCache[i].lastConfirmedAt = s.end
            }
            self.updateJournalSummary()
            // Fold the freshly-journalled slice into an adjacent same-task
            // neighbour, so live-created slices auto-merge exactly the way
            // drag-edited ones already do — one slice, one OP entry. A manual
            // Stop→Start leaves a real untracked gap, so it stays discrete;
            // a contiguous continue/revert/claim folds into the prior slice.
            Task {
                await self.coalesceAdjacent(around: s.start)
                await self.syncIfEnabled()
            }
        }
        tracker.onReview = { [weak self] segment in
            guard let self else { return }
            try? self.journal.save(segment)
            self.reloadReview()
        }
        tracker.onState = { [weak self] state in
            guard let self else { return }
            DebugLog.write("state -> \(state)")
            self.trackerState = state
            let now = Date()
            if case .tracking(let target, _) = state {
                if target != self.currentTarget {
                    // Every visit is credited to its own task's session
                    // accumulator. A brief excursion does NOT reset the task
                    // you came from — returning resumes it (Martin: 5s in
                    // scratch then back to HighgateOS shows HighgateOS's 5s, not 0).
                    if let old = self.currentTarget, let since = self.targetSince {
                        self.bankedElapsed[old, default: 0] += now.timeIntervalSince(since)
                    }
                    if case .task(let oldRef) = self.currentTarget, .task(oldRef) != target {
                        self.previousTask = oldRef
                    }
                    self.currentTarget = target
                    self.targetSince = now
                    self.visitSolid = false
                    self.taskChangedAt = now
                    // The old task's slice has already been flushed by the
                    // tracker on this switch, so the 60 s checkpoint still
                    // pointing at the OLD [start,end] would, on a crash in this
                    // window, be promoted to a slice overlapping the flushed one
                    // (duplicate time + duplicate OP entry). Clear it and
                    // re-anchor to the new task's start (targetSince is `now`,
                    // already set above, which checkpointLive reads).
                    self.clearCheckpoint()
                    self.checkpointLive()
                    // NB: the note is NOT cleared here. A display switch (incl.
                    // a sub-grace excursion that reverts) used to wipe the note
                    // before the slice it belonged to was flushed, losing it.
                    // The note is now consumed at flush time (onSession) and on
                    // stop, so it follows its slice correctly.
                }
            } else {
                self.currentTarget = nil
                self.targetSince = nil
                self.visitSolid = false
                self.bankedElapsed.removeAll()
                self.manualNote = ""
                self.taskChangedAt = now
                self.clearCheckpoint()   // nothing in flight to recover
                Notifier.notify(symbol: "stop.circle", text: "Stopped", sound: "Basso")
            }
            self.refreshTitle(force: true)
        }
        tracker.onDebug = { message in
            DebugLog.write(message)
        }
        tracker.onSpanClosed = { [weak self] span in
            try? self?.journal.save(span)
        }
        tracker.onPrompt = { [weak self] prompt in
            guard let self else { return }
            self.lastPrompt = prompt
            switch prompt {
            case .taskChanged(let target):
                Notifier.notify(symbol: "arrow.right", text: self.name(of: target),
                                sound: "Tink")
            case .resumeAfterIdle(let stoppedAt):
                // The gap defaults to a break (nothing recorded); offer a
                // one-tap claim onto the task we were on, in case it was work.
                if let last = self.lastTrackedTask() {
                    self.pendingGap = IdleGap(task: last.ref, from: stoppedAt, to: Date())
                    Notifier.notify(symbol: "sun.max",
                                    text: "Back — tap to count the gap as \(last.subject)",
                                    sound: "Tink")
                } else {
                    Notifier.notify(symbol: "sun.max", text: "Welcome back", sound: "Tink")
                }
            case .callEnded:
                Notifier.notify(symbol: "phone.down", text: "Call ended — assign it?",
                                sound: "Tink")
            }
        }
    }

    /// Every dead-end here reports WHY via lastError — silent guards cost a
    /// debugging round-trip on 2026-06-11.
    private func rebuildClient() {
        client = nil
        connectedAs = nil
        let raw = settings.opBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        attributor.instanceHost = URL(string: raw)?.host ?? ""
        guard !raw.isEmpty else {
            lastError = nil   // unconfigured is not an error
            return
        }
        guard let url = URL(string: raw), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            lastError = "OP URL must start with http:// or https:// and include a host"
            return
        }
        let key: String?
        do {
            key = try APIKeyStore.loadAPIKey()
        } catch {
            lastError = "Cannot read API key – \(error). Re-enter and Save."
            return
        }
        guard let key else {
            lastError = "No API key yet – open Settings (gear icon) and add your OpenProject API key"
            return
        }
        client = OPClient(baseURL: url, apiKey: key, transport: URLSessionTransport())
        lastError = nil
    }

    // MARK: - Away ("I'm leaving my desk") and scheduled stop

    @Published public private(set) var away = false
    private var scheduledStop: Date?

    /// Keep tracking the current task no matter what (idle, app switches,
    /// sleep) until cleared. Optionally lock the Mac as you leave.
    public func setAway(_ on: Bool) {
        guard case .tracking = trackerState else { away = false; tracker.away = false; return }
        away = on
        tracker.away = on
        DebugLog.write("away = \(on)")
        if on {
            Notifier.notify(symbol: "figure.walk", text: "Away — still tracking \(currentTaskName())",
                            sound: "Tink")
            if settings.lockOnLeave { lockScreen() }
        } else {
            Notifier.notify(symbol: "figure.walk.motion", text: "Back — \(currentTaskName())",
                            sound: "Tink")
        }
        refreshTitle(force: true)
    }

    /// Auto-stop at a future time (the live slice's end dragged forward, e.g.
    /// a meeting end). nil clears it.
    public func scheduleStop(at date: Date?) {
        scheduledStop = date
        if let date { DebugLog.write("scheduled stop at \(date)") }
    }

    private func lockScreen() {
        // Ctrl-Cmd-Q locks the screen on modern macOS; we already hold the
        // Accessibility right needed to post it.
        let src = "tell application \"System Events\" to key code 12 using {control down, command down}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", src]
        try? process.run()
    }

    // MARK: - Lifecycle

    public func startUp() {
        installCrashTraps()
        installUndoKey()
        installAwayHotKey()
        promoteStaleCheckpoint()   // recover any session a crash/quit left mid-flight
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // queue: .main → this runs on the main actor; assert it so the
            // call is synchronous (must finish before the app quits).
            MainActor.assumeIsolated {
                self?.checkpointLive()
                self?.awayHotKey = nil   // unregister the Carbon hotkey before quit
            }
        }
        Notifier.enabled = settings.systemNotifications
        sensors.requestPermissions()
        sensors.onEvent = { [weak self] event in
            switch event {
            case .input: break   // 2 s ticks would drown the log
            default: DebugLog.write("sensor \(event)")
            }
            self?.tracker.handle(event)
        }
        DebugLog.write("startUp: AX trusted=\(sensors.accessibilityTrusted) grace=\(settings.switchGraceSeconds)s")
        sensors.start()
        Notifier.requestAuthorization()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let stop = self.scheduledStop, Date() >= stop {
                    self.scheduledStop = nil
                    if self.away { self.setAway(false) }
                    self.userStopped()
                }
                self.refreshTitle(force: false)
            }
        }
        taskRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkpointLive()        // crash-safety: persist the in-flight session
                await self?.refreshTasks()
                await self?.syncIfEnabled()   // retry path for failed/late pushes
            }
        }
        // Tight crash-safety cadence: checkpointLive itself no-ops unless we're
        // .tracking, so a stopped app does nothing here. The 5 s tolerance lets
        // the OS batch this with other timer fires — no extra wakeups.
        let cp = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpointLive() }
        }
        cp.tolerance = 5
        checkpointTimer = cp
        Task { await refreshTasks() }
        reloadReview()
    }

    /// Change-detection instead of interval gating: a 1 Hz timer gated by
    /// ">= 1 s since last refresh" skipped alternate ticks (even-seconds bug)
    /// and froze the text across the minute boundary. Computing every tick
    /// and assigning only on change gives 1 Hz updates in the first minute
    /// and per-minute after — by construction, since that is when the string
    /// changes.
    private func refreshTitle(force: Bool) {
        let newText: String
        let newColour: NSColor
        switch trackerState {
        case .stopped:
            newText = "–"
            newColour = MenuTitle.colour(certainty: nil, lowHex: settings.colourLow,
                                         highHex: settings.colourHigh)
        case .tracking(let target, let certainty):
            let now = Date()
            let running = targetSince.map { now.timeIntervalSince($0) } ?? 0
            // When THIS task's current visit survives the grace it has "taken
            // over": every OTHER task's session is now ended (a real stint
            // elsewhere starts fresh on return). Brief excursions never reach
            // here, so they leave the other accumulators intact — the clock
            // shows the current contiguous session, i.e. what would post to OP.
            if !visitSolid, running >= settings.switchGraceSeconds {
                visitSolid = true
                bankedElapsed = bankedElapsed.filter { $0.key == target }
            }
            // tracker.liveSliceStart spans the whole contiguous stretch —
            // INCLUDING sub-grace excursion windows that reverted back to this
            // task — so it recovers re-tagged seconds the per-visit banked figure
            // drops; banked+running is the fallback when no live slice is open.
            let elapsed = MenuTitle.displayedElapsed(
                liveSliceStart: tracker.liveSliceStart,
                bankedFallback: bankedElapsed[target, default: 0],
                running: running, now: now)
            let body = MenuTitle.text(elapsed: elapsed, certainty: certainty,
                                      showPercent: settings.showPercent)
            // Elapsed WITHOUT the task name — the popover already shows the task
            // as its headline, so menuText (which carries the name for the menu
            // bar) would duplicate it there.
            elapsedText = body
            // menuTaskChars == 0 → withTaskName returns the body unchanged (off).
            newText = MenuTitle.withTaskName(name(of: target), chars: settings.menuTaskChars,
                                             body: body)
            newColour = MenuTitle.colour(certainty: certainty, lowHex: settings.colourLow,
                                         highHex: settings.colourHigh)
        }
        if force || newText != menuText { menuText = newText }
        if force || !newColour.isEqual(menuColour) { menuColour = newColour }
    }

    // MARK: - Crash-safe recording

    /// A fixed-id provisional row mirroring the in-flight session, rewritten
    /// every minute and on quit. Never pushed to OP (pushedToOP=true sentinel).
    /// If a crash leaves it behind, startUp promotes it to a real slice — so
    /// tracked time survives even an unclean exit.
    static let liveCheckpointID = UUID(uuidString: "00000000-0000-0000-0000-0000C0FFEE00")!

    public func checkpointLive() {
        guard case .tracking(.task(let ref), let certainty) = trackerState,
              let since = targetSince else { return }
        try? journal.update(Session(id: Self.liveCheckpointID, task: ref, start: since,
                                    end: Date(), certainty: certainty, pushedToOP: true))
    }

    private func clearCheckpoint() {
        try? journal.deleteSession(Self.liveCheckpointID)
    }

    private func promoteStaleCheckpoint() {
        let all = (try? journal.allSessions()) ?? []
        let stale = all.first { $0.id == Self.liveCheckpointID }
        // Real journalled slices only (drop the checkpoint row itself) — these
        // are what a switch-flush would already have written, so an overlap with
        // them means promoting the checkpoint would duplicate time + OP entry.
        let journalled = all.filter { $0.id != Self.liveCheckpointID }
        guard let recovered = CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: journalled) else {
            clearCheckpoint(); return
        }
        // Recover crash-lost time as a real, pushable slice.
        try? journal.save(Session(task: recovered.task, start: recovered.start,
                                  end: recovered.end, certainty: recovered.certainty,
                                  comment: "recovered after restart"))
        clearCheckpoint()
        DebugLog.write("recovered crash-lost session \(recovered.start)..\(recovered.end)")
    }

    // MARK: - User actions

    public func currentTaskName() -> String {
        if case .tracking(let target, _) = trackerState { return name(of: target) }
        return "Not tracking"
    }

    public func name(of target: Target) -> String {
        switch target {
        case .doNotTrack: return "Do not track"
        case .task(let ref):
            if let t = taskCache.first(where: { $0.ref == ref }) { return t.subject }
            if case .op(let id) = ref { return "WP #\(id)" }
            return "Leisure"
        }
    }

    /// Make recency durable across restarts. `lastConfirmedAt` is otherwise an
    /// in-memory field (stamped on pick and on live-slice flush) that resets to
    /// nil every launch, so a heavily-tracked task silently drops out of the
    /// recent pick-list after an app restart — e.g. the morning after an
    /// overnight gap, the exact "where did Client Work go?" symptom. The journal
    /// is the durable record of what was actually tracked, so we re-derive each
    /// task's last-tracked time from it and take the later of that and any
    /// in-memory value.
    private func applyJournalRecency() {
        var lastEnd: [TaskRef: Date] = [:]
        for s in ((try? journal.allSessions()) ?? []) where s.id != Self.liveCheckpointID {
            lastEnd[s.task] = max(lastEnd[s.task] ?? .distantPast, s.end)
        }
        for i in taskCache.indices {
            if let l = lastEnd[taskCache[i].ref] {
                taskCache[i].lastConfirmedAt =
                    max(taskCache[i].lastConfirmedAt ?? .distantPast, l)
            }
        }
    }

    /// The popover / picker ordering: recently-confirmed tasks first (most
    /// recent first), then everything else ranked. The whole list — it's
    /// scrollable and filterable, so there's no recent/likely cap any more.
    public func fullPickList() -> [WorkTask] {
        TaskRanker(config: RankingConfig(statusOrder: settings.statusOrder,
                                         currentUser: connectedAs))
            .recentThenRanked(taskCache, at: Date(), learning: attributor.learning)
    }

    public func userPicked(_ task: WorkTask) {
        tracker.confirm(task: task.ref, at: Date())
        if let i = taskCache.firstIndex(where: { $0.ref == task.ref }) {
            taskCache[i].lastConfirmedAt = Date()
        }
        persistAssociations()
        lastPrompt = nil
    }

    private func persistAssociations() {
        try? learningStore.save(attributor.learning)
        try? primedStore.save(attributor.primedSurfaces)
        try? pinsStore.save(attributor.pins)
        try? emailRulesStore.save(attributor.emailRules)
    }

    /// The full broad→narrow identity of the current focus surface plus the
    /// smart default prefix length — the pin editor's starting state. nil when
    /// there's nothing to pin (no current surface).
    public func pinDraft() -> (kind: PinScope.Kind, segments: [String], defaultCount: Int)? {
        guard let signal = tracker.currentFocusSignal,
              let id = PinScope.identity(of: signal) else { return nil }
        return (id.kind, id.segments,
                PinScope.defaultPrefixCount(kind: id.kind, segments: id.segments))
    }

    /// Commit a component-prefix pin: the chosen prefix is ALWAYS `ref` at
    /// 100 %. When `replacingID` is given (editing an existing pin) the same id
    /// is reused, so a changed scope updates in place instead of duplicating.
    public func commitPin(kind: PinScope.Kind, prefix: [String], to ref: TaskRef,
                          replacingID: UUID? = nil, priority: Int? = nil) {
        guard !prefix.isEmpty else { return }
        commitPin(rule: .components(PinScope(kind: kind, prefix: prefix)),
                  to: ref, replacingID: replacingID, priority: priority)
    }

    /// Commit any pin rule (components OR a boolean expression) — the general
    /// path the Expression editor and the AI mode both feed into. `replacingID`
    /// reuses the id so editing updates in place instead of duplicating.
    public func commitPin(rule: PinRule, to ref: TaskRef, replacingID: UUID? = nil,
                          priority: Int? = nil) {
        let pin = Pin(id: replacingID ?? UUID(), rule: rule, task: ref, priority: priority)
        attributor.upsert(pin)
        persistAssociations()
        tracker.reevaluate()   // lift the live session to 100% now, not on next focus
        objectWillChange.send()
    }

    /// The pin (+ its task) covering the current focus surface, if any — drives
    /// the popover's 📌 badge. nil for ranked / soft-primed surfaces.
    public var currentPin: (pin: Pin, task: WorkTask)? {
        guard let signal = tracker.currentFocusSignal,
              let pin = attributor.matchingPin(for: signal),
              let task = taskCache.first(where: { $0.ref == pin.task }) else { return nil }
        return (pin, task)
    }

    /// Clear the pin covering the current focus surface (the badge's ✕).
    public func unpinCurrentSurface() {
        guard let signal = tracker.currentFocusSignal,
              let pin = attributor.matchingPin(for: signal) else { return }
        attributor.unpin(id: pin.id)
        persistAssociations()
        objectWillChange.send()
    }

    public func userStopped() {
        if away { away = false; tracker.away = false }
        scheduledStop = nil
        tracker.stop(at: Date())
    }

    /// "Change to": relabel the RUNNING session to `ref`, keeping its elapsed
    /// time (the mis-attributed time moves to the right task, the clock does
    /// not reset). Distinct from userPicked, which starts a fresh session.
    public func changeCurrentTask(to ref: TaskRef, undoable: Bool = true) {
        guard case .tracking(let oldTarget, _) = trackerState, .task(ref) != oldTarget else { return }
        // Make the popover relabel reversible: ⌘Z relabels back to the task it
        // was on (the inverse is itself a change, marked non-undoable so it
        // doesn't stack endlessly).
        if undoable, case .task(let oldRef) = oldTarget {
            registerUndo("change to \(name(of: oldTarget))") { [weak self] in
                self?.changeCurrentTask(to: oldRef, undoable: false)
            }
        }
        let now = Date()
        let elapsed = (bankedElapsed[oldTarget] ?? 0)
            + (targetSince.map { now.timeIntervalSince($0) } ?? 0)
        let keptNote = manualNote
        tracker.relabelCurrentSession(to: ref)   // re-tags spans; fires onState
        // Durably TEACH this window→task, not just the soft prime relabel does:
        // otherwise the learned model re-wins and the window snaps back to its
        // old task when focus returns (Martin: "Change to Ambitick" kept
        // reverting to a 70%-certain KLARC on every return).
        if let signal = tracker.currentFocusSignal {
            attributor.assign(signal, target: .task(ref))
            persistAssociations()
        }
        // Preserve the displayed clock onto the corrected task and continue.
        currentTarget = .task(ref)
        targetSince = now.addingTimeInterval(-elapsed)
        bankedElapsed = [:]
        visitSolid = true
        manualNote = keptNote
        if let i = taskCache.firstIndex(where: { $0.ref == ref }) {
            taskCache[i].lastConfirmedAt = now
        }
        persistAssociations()
        refreshTitle(force: true)
    }

    public func userPostponed() {
        lastPrompt = nil
    }

    /// Turn the live (ongoing) slice into a real, editable timeline slice ending
    /// now, while continuing to track the same task from now — so the live track
    /// can be edited without stopping it. Returns the just-journalled slice.
    @discardableResult
    public func commitLiveSlice() -> Session? {
        guard case .tracking(.task(let ref), _) = trackerState else { return nil }
        let now = Date()
        let from = tracker.liveSliceStart ?? targetSince ?? now
        tracker.commitLive(at: now)
        // Keep the displayed clock continuous: the committed time is now banked,
        // the fresh run starts at `now`.
        targetSince = now
        bankedElapsed = [.task(ref): now.timeIntervalSince(from)]
        visitSolid = true
        updateJournalSummary()
        refreshTitle(force: true)
        // Search from the live slice's own start (not the calendar day) so a
        // slice that began before midnight is still found.
        return ((try? journal.sessions(from: from.addingTimeInterval(-2), to: now)) ?? [])
            .filter { $0.task == ref && $0.id != Self.liveCheckpointID }
            .max(by: { $0.end < $1.end })
    }

    // MARK: - Per-task workspaces (window layouts)

    // Workspace layouts were cut 2026-06-23: geometry-only restore (no Chrome
    // tab/URL, no terminal cwd) plus unreliable multi-window/Spaces spawning
    // made it net-negative. See TODO.md for what re-adding it would require.

    /// One-tap: the idle gap WAS work — record it on its task, keeping the
    /// window detail that was captured around it. Zero taps leaves it a break.
    public func claimIdleGap() {
        guard let g = pendingGap else { return }
        pendingGap = nil
        Task {
            await createTimelineSession(Session(task: g.task, start: g.from, end: g.to,
                                                certainty: 0.95, comment: "worked through idle gap"))
            // Continue, don't split: merge the claimed gap into the prior
            // same-task slice it butts up against, so "continue when away"
            // yields one continuous slice / one OP entry.
            await coalesceAdjacent(around: g.from)
        }
    }

    public func dismissIdleGap() { pendingGap = nil }

    /// Post a note to the task's activity feed (OP work-package comment), so
    /// 'comment to task' notes are findable on the task itself. With no backend
    /// attached this is a no-op today; standalone storage lands with the
    /// backend-seam refactor (a local timestamped comment list).
    private func postTaskComment(wpID: Int, note: String) async {
        guard let client else { return }
        do {
            try await client.addWorkPackageComment(id: wpID, text: note)
            DebugLog.write("posted task comment to WP #\(wpID)")
        } catch {
            lastError = "OP task comment failed: \(error)"
        }
    }

    public func assignReview(_ ids: [UUID], to target: Target, undoable: Bool = true) {
        if undoable {
            let learningSnapshot = attributor.learning
            let primedSnapshot = attributor.primedSurfaces
            let pinsSnapshot = attributor.pins
            registerUndo("assign \(ids.count) review rows") { [weak self] in
                guard let self else { return }
                try? self.journal.assign(ids, to: nil)
                self.attributor.replaceLearning(learningSnapshot)
                self.attributor.primedSurfaces = primedSnapshot
                self.attributor.pins = pinsSnapshot
                self.persistAssociations()
                self.reloadReview()
            }
        }
        try? journal.assign(ids, to: target)
        if let segment = pendingReview.first(where: { ids.contains($0.id) }) {
            let signal = ActivitySignal(app: segment.app, windowTitle: segment.windowTitle,
                                        tabURL: segment.tabURL, timestamp: segment.start)
            attributor.assign(signal, target: target)
            persistAssociations()
        }
        reloadReview()
    }

    private func reloadReview() {
        pendingReview = (try? journal.pendingReview()) ?? []
        updateJournalSummary()
    }

    /// Bumped on every journal mutation (this is called on all of them), so a
    /// view can invalidate a cached journal read without polling — even when the
    /// summary STRING is unchanged (e.g. a same-duration reassign).
    @Published public private(set) var journalRevision = 0

    private func updateJournalSummary() {
        // COUNT queries instead of decoding the whole table. The checkpoint row
        // (pushedToOP=true sentinel) is counted in both totals, exactly as the
        // old allSessions()-minus-checkpoint logic netted out: total includes it
        // and `handled` includes it, so both shift by one and the visible
        // "journalled vs handled" arithmetic is unchanged. (The row is normally
        // absent — present only while a live session is in flight.)
        let total = (try? journal.sessionCount()) ?? 0
        let pushed = (try? journal.pushedCount()) ?? 0
        let awaiting = (try? journal.sessions(
            needingPushAtOrAbove: settings.certaintyAutoPushThreshold).count) ?? 0
        journalSummary = "\(total) sessions journalled · \(pushed) handled · \(awaiting) awaiting push"
        journalRevision &+= 1
    }

    // MARK: - Undo

    /// Infinite, session-bounded undo of data edits (timeline, review,
    /// local tasks, colours). ⌘Z anywhere in the app.
    private var undoStack: [(label: String, inverse: () async -> Void)] = []
    @Published public private(set) var undoCount = 0
    private var pendingGroup: [() async -> Void]?

    private func registerUndo(_ label: String, inverse: @escaping () async -> Void) {
        if pendingGroup != nil {
            pendingGroup?.append(inverse)   // accumulate; the group pushes one entry
        } else {
            undoStack.append((label, inverse))
            undoCount = undoStack.count
        }
    }

    /// Bundle every mutation in `body` into ONE undo step (a handle drag that
    /// overwrites several records, or an overlap save that trims a neighbour
    /// and moves a slice, undoes in a single ⌘Z). Nestable.
    public func undoGroup(_ label: String, _ body: () async -> Void) async {
        let outer = pendingGroup == nil
        if outer { pendingGroup = [] }
        await body()
        if outer, let group = pendingGroup {
            pendingGroup = nil
            if !group.isEmpty {
                undoStack.append((label, { for inverse in group.reversed() { await inverse() } }))
                undoCount = undoStack.count
            }
        }
    }

    public func undo() {
        guard let last = undoStack.popLast() else {
            NSSound(named: "Funk")?.play()
            return
        }
        undoCount = undoStack.count
        Notifier.notify(symbol: "arrow.uturn.backward", text: last.label, sound: "Pop")
        Task { await last.inverse() }
    }

    private func installUndoKey() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "z" {
                self?.undo()
                return nil
            }
            return event
        }
    }

    /// True system-wide ⌘⇧L: toggles Away from any app (kVK_ANSI_L = 37). The
    /// popover's SwiftUI .keyboardShortcut only fires while Ambitick is key, so
    /// this is the one that works on your way out of the room. setAway no-ops
    /// unless we're .tracking, so the chord is harmless when stopped.
    private func installAwayHotKey() {
        let signature = OSType(0x416D6274)   // 'Ambt'
        awayHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | shiftKey),
            signature: signature,
            id: 1) { [weak self] in
            guard let self else { return }
            self.setAway(!self.away)
        }
        if awayHotKey == nil {
            DebugLog.write("global ⌘⇧L hotkey: registration failed")
        }
    }

    deinit {
        // Belt-and-braces: also unregister if the controller is torn down
        // without a willTerminate (e.g. in tests / previews). deinit runs
        // GlobalHotKey.deinit which unregisters the Carbon hotkey + handler.
        awayHotKey = nil
    }

    // MARK: - Timeline

    /// Sessions overlapping an arbitrary [from, to] window — the continuous
    /// timeline's fetch, so a viewport can span midnight / several days — plus
    /// the synthetic live slice (folded into the same-task block it continues)
    /// when the current visit overlaps the window.
    public func timelineSessions(from: Date, to: Date) -> [Session] {
        // The live checkpoint row is internal crash-recovery state, not a
        // user-facing slice — never draw it on the timeline.
        var list = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        if case .tracking(.task(let ref), let certainty) = trackerState {
            var liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
            let liveEnd = Date()
            guard liveEnd > from, liveStart < to else { return list }
            // Fold the live slice visually into the same-task block it
            // continues (the journal only coalesces on flush): walk back over
            // contiguous same-task journalled slices, drop them, extend the
            // live start to cover them.
            while let i = list.firstIndex(where: {
                $0.task == ref && $0.start < liveStart
                    && abs($0.end.timeIntervalSince(liveStart)) <= 2 }) {
                liveStart = Swift.min(liveStart, list[i].start)
                list.remove(at: i)
            }
            list.append(Session(id: Self.liveSessionID, task: ref, start: liveStart,
                                end: liveEnd, certainty: certainty))
        }
        return list
    }

    public static let liveSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!

    /// One reusable ISO-8601 formatter for OP pushes — it was allocated per
    /// push in several paths (allocating a formatter is not cheap).
    private static let iso8601 = ISO8601DateFormatter()

    /// A slice the timeline should frame + open when it next appears — set when
    /// you click a slice in the pie window's mini-timeline. The timeline consumes
    /// and clears it.
    @Published public var pendingTimelineFocus: Session?

    /// The view shown in the single Time window, and in the optional second
    /// window (control/right-click a preview). Flipping the primary in place is
    /// the normal "switch"; the second window is the escape hatch for both at
    /// once.
    @Published public var timeWindowView: TimeView = .timeline
    @Published public var timeWindow2View: TimeView = .spent

    /// Record which time view is showing (persists, so "last viewed" survives a
    /// relaunch).
    public func noteTimeViewOpened(_ which: TimeView) {
        if settings.lastViewedTimeView != which { settings.lastViewedTimeView = which }
    }

    /// Scan OP for duplicate time entries over a recent window and plan the
    /// richest-survivor reconcile against the journal. Empty when not connected
    /// or nothing duplicated.
    public func findDuplicateActions(daysBack: Int = 90) async -> [ReconcileAction] {
        guard let client else { return [] }
        let to = Date()
        let from = to.addingTimeInterval(-Double(daysBack) * 86_400)
        let entries = (try? await client.listTimeEntries(from: from, to: to)) ?? []
        let sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        return DuplicateReconcile.plan(entries: entries, sessions: sessions)
    }

    /// Apply ONE confirmed reconcile: fold the deleted entries' comments into the
    /// survivor, delete the duplicates, and re-point the journal slices so future
    /// edits still PATCH the right entry. Nothing is lost.
    public func applyReconcile(_ action: ReconcileAction) async {
        guard let client else { return }
        if let merged = action.mergedComment {
            try? await client.updateTimeEntryComment(id: action.survivorID, comment: merged)
        }
        for id in action.deleteIDs {
            try? await client.deleteTimeEntry(id: id)
        }
        for sid in action.repointSessionIDs {
            if var s = try? journal.session(id: sid) {
                s.opTimeEntryID = action.survivorID
                try? journal.update(s)
            }
        }
        updateJournalSummary()
    }

    /// Today's project breakdown + total (the timeline window's mini-pie
    /// cross-preview).
    public func todaySpentNodes() -> [TimeAggregator.Node] {
        spentNodes(from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    /// The latest work block's slices + extent (the pie window's mini-timeline
    /// cross-preview). nil when there's no recent activity.
    public func currentBlock() -> (sessions: [Session], start: Date, end: Date)? {
        let recent = timelineSessions(from: Date().addingTimeInterval(-2 * 86_400), to: Date())
        guard let block = TimelineMath.latestBlock(in: recent) else { return nil }
        let slices = recent.filter { $0.end > block.start && $0.start < block.end }
        return (slices, block.start, block.end)
    }

    /// Which view the single Time window opens on, per the 3-way setting.
    public func initialTimeView() -> TimeView {
        switch settings.timeViewOpenMode {
        case .timeline: return .timeline
        case .spent: return .spent
        case .lastViewed: return settings.lastViewedTimeView
        }
    }

    public func timelineSpans(for session: Session) -> [FocusSpan] {
        (try? journal.spans(from: session.start, to: session.end)) ?? []
    }

    /// Why the attributor would pick a task for this window — drives the
    /// timeline's "why was this tracked as X?" panel. Scored at the window's own
    /// time so the time-of-day prior matches what actually happened.
    public func explainSpan(_ span: FocusSpan) -> AttributionExplanation {
        attributor.explain(span.signal, tasks: taskCache, now: span.signal.timestamp)
    }

    /// Teach the attributor that this window is `ref` (a strong correction, like
    /// a confirmation): future time on it attributes here. The visible "edit the
    /// weighting" action behind the why-panel.
    public func teachSurface(_ span: FocusSpan, to ref: TaskRef) {
        attributor.confirm(span.signal, task: ref)
        persistAssociations()
        tracker.reevaluate()
        objectWillChange.send()
    }

    public func boostSurface(_ span: FocusSpan, to ref: TaskRef, weight: Double = 4) {
        attributor.learnSurface(span.signal, to: ref, weight: weight)
        persistAssociations(); tracker.reevaluate(); objectWillChange.send()
    }

    public func pinSurface(_ span: FocusSpan, to ref: TaskRef) {
        guard let id = PinScope.identity(of: span.signal) else {
            boostSurface(span, to: ref, weight: 6); return
        }
        let n = PinScope.defaultPrefixCount(kind: id.kind, segments: id.segments)
        commitPin(kind: id.kind, prefix: Array(id.segments.prefix(n)), to: ref)
    }

    /// Per-task colour: user override first, stable hash otherwise.
    public func colour(for ref: TaskRef) -> NSColor {
        if let hex = settings.taskColours[ref.storageKey], let c = NSColor(hex: hex) {
            return c
        }
        var hash: UInt64 = 5381
        for byte in String(describing: ref).utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
    }

    public func setColour(_ colour: NSColor, for ref: TaskRef) {
        let previous = settings.taskColours[ref.storageKey]
        registerUndo("colour change") { [weak self] in
            self?.settings.taskColours[ref.storageKey] = previous
        }
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        let hex = String(format: "#%02X%02X%02X",
                         Int(rgb.redComponent * 255),
                         Int(rgb.greenComponent * 255),
                         Int(rgb.blueComponent * 255))
        settings.taskColours[ref.storageKey] = hex
    }

    /// Forgiving search over the full ranked task list.
    public func searchTasks(_ query: String) -> [WorkTask] {
        FuzzyMatch.filter(fullPickList(), query: query)
    }

    /// Sorted, de-duplicated window (focus-span) edges in [from, to] — the
    /// times an edit can snap to so a tracked window lands wholly in one task
    /// instead of being split across the slice boundary.
    public func windowBoundaries(from: Date, to: Date) -> [Date] {
        var edges = Set<Date>()
        for s in (try? journal.spans(from: from, to: to)) ?? [] {
            edges.insert(s.start)
            edges.insert(s.end)
        }
        return edges.sorted()
    }

    /// Time Spent hierarchy for the pie: project -> task -> app, including
    /// the live session when the range covers now. Sessions crossing the
    /// range boundary are clipped so totals never double-count across days.
    public func spentNodes(from: Date, to: Date) -> [TimeAggregator.Node] {
        var sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }   // internal recovery row
            .map { s -> Session in
                var c = s
                c.start = max(s.start, from)
                c.end = min(s.end, to)
                return c
            }
        if case .tracking(.task(let ref), let certainty) = trackerState,
           let since = tracker.liveSliceStart ?? targetSince, since < to, Date() > from {
            sessions.append(Session(id: Self.liveSessionID, task: ref,
                                    start: max(since, from), end: min(Date(), to),
                                    certainty: certainty))
        }
        let spans = (try? journal.spans(from: from, to: to)) ?? []
        return TimeAggregator.byProject(sessions: sessions, tasks: taskCache, spans: spans)
    }

    /// The journalled slices a live-start drag from `liveStart` back to
    /// `newStart` spans (live/checkpoint rows excluded). The overlap WARNING and
    /// the absorb TRIM BOTH derive from this one window, so what the user is
    /// warned about always equals what actually gets trimmed — a calendar-day
    /// anchor (used before) desynced the two when the drag crossed midnight.
    /// Bounded by the drag distance, never a full-history scan.
    private func liveEditContext(from newStart: Date, to liveStart: Date) -> [Session] {
        ((try? journal.sessions(from: newStart.addingTimeInterval(-2), to: liveStart)) ?? [])
            .filter { $0.id != Self.liveSessionID && $0.id != Self.liveCheckpointID }
    }

    /// Different-task slices the live start would cross if dragged to
    /// `newStart` — what an absorb would trim/delete. The timeline shows these
    /// as a warning before the second Save confirms.
    public func liveStartConflicts(newStart: Date) -> [Session] {
        guard case .tracking(.task(let ref), _) = trackerState else { return [] }
        let liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
        guard newStart < liveStart else { return [] }
        return liveEditContext(from: newStart, to: liveStart)
            .filter { $0.task != ref && $0.end > newStart && $0.start < liveStart }
            .sorted { $0.start < $1.start }
    }

    /// Timeline edit of the live slice's start. Dragging it back behaves like
    /// dragging any slice's edge: same-task slices it reaches fold in (deleted,
    /// their time and comment absorbed into the one ongoing slice), and — when
    /// `absorbOtherTasks` is set (the timeline confirms via a warning first) —
    /// other-task slices it crosses are trimmed/deleted through the very same
    /// TimelineMath.trims path a normal edge drag uses. One undo step.
    public func adjustLiveStart(to date: Date, absorbOtherTasks: Bool = false) async {
        guard case .tracking(.task(let ref), _) = trackerState else { return }
        let liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
        // Same window as the warning (liveStartConflicts) so warn-set == absorb-
        // set even across midnight.
        let context = liveEditContext(from: min(date, Date()), to: liveStart)

        let sameTask = context.filter {
            $0.task == ref && $0.start < liveStart
                && $0.end >= min(date, Date()).addingTimeInterval(-2)
        }
        let newStart = ([min(date, Date())] + sameTask.map(\.start)).min() ?? min(date, Date())
        let foldedNote = sameTask
            .compactMap { ($0.comment?.isEmpty == false) ? $0.comment : nil }
            .joined(separator: "; ")
        let otherTrims = absorbOtherTasks
            ? TimelineMath.trims(for: newStart, liveStart, in: context.filter { $0.task != ref })
            : []

        await undoGroup("extend \(name(of: .task(ref)))") {
            for s in sameTask { await deleteTimelineSession(s) }
            for trim in otherTrims {
                if trim.delete { await deleteTimelineSession(trim.session) }
                else { await applyTimelineEdit(trim.session) }
            }
            if !sameTask.isEmpty || !otherTrims.isEmpty {
                tracker.backdateSessionStart(to: newStart)
                if !foldedNote.isEmpty, manualNote.isEmpty { manualNote = foldedNote }
            } else {
                tracker.adjustCurrentStart(to: newStart)
            }
            targetSince = newStart
            bankedElapsed = [:]
        }
        updateJournalSummary()
        refreshTitle(force: true)
    }

    /// The most recently tracked task — the obvious resume candidate. Looks back
    /// 36 h, not just "today", so just after midnight the candidate is still the
    /// task you were on at 23:50 rather than nothing.
    public func lastTrackedTask() -> WorkTask? {
        let lookback = Date().addingTimeInterval(-36 * 3600)
        guard let last = ((try? journal.sessions(from: lookback, to: Date())) ?? [])
            .filter({ $0.id != Self.liveCheckpointID }).last else {
            return nil
        }
        return taskCache.first { $0.ref == last.task }
    }

    /// The task to "revert" to: the last closed slice's task, but only when it
    /// differs from what we're tracking now (otherwise there is nothing to
    /// undo). Drives the popover's one-click "← <prev>" when a switch was wrong.
    public func revertTargetTask() -> WorkTask? {
        guard case .tracking(let current, _) = trackerState else { return nil }
        guard let prev = previousTask, .task(prev) != current,
              let task = taskCache.first(where: { $0.ref == prev }) else { return nil }
        return task
    }

    /// "That switch was wrong": fold the current (mis-attributed) running slice
    /// back onto the previous task, keeping the clock — no reset. Same machinery
    /// as the popover's "Change to".
    public func revertToLastTask() {
        guard let target = revertTargetTask() else { return }
        changeCurrentTask(to: target.ref)
    }

    /// A brand-new manual slice (drawn or gap-filled on the timeline).
    public func createTimelineSession(_ session: Session) async {
        try? journal.save(session)
        registerUndo("create \(name(of: .task(session.task)))") { [weak self] in
            guard let self else { return }
            let saved = try? self.journal.session(id: session.id)
            await self.deleteTimelineSession(saved ?? session, undoable: false)
        }
        updateJournalSummary()
        await syncIfEnabled()
    }

    /// Persist a timeline edit; PATCH the OP entry when one exists.
    public func applyTimelineEdit(_ session: Session, undoable: Bool = true) async {
        if undoable,
           let previous = try? journal.session(id: session.id) {
            registerUndo("edit \(name(of: .task(previous.task)))") { [weak self] in
                await self?.applyTimelineEdit(previous, undoable: false)
            }
        }
        var session = session
        let previous = try? journal.session(id: session.id)
        // Task changed (e.g. a mis-filed slice reassigned in the editor): the
        // old OP entry belongs to the old work package — delete it, drop the
        // id, and let sync recreate under the new task. Also teach the
        // attributor so the same surface stops mis-filing in future.
        if let previous, previous.task != session.task {
            if let oldEntry = previous.opTimeEntryID, let client {
                try? await client.deleteTimeEntry(id: oldEntry)
            }
            session.opTimeEntryID = nil
            session.pushedToOP = false
            teachAssociation(for: session)
        }
        // A sub-minute session was marked handled without an OP entry; if an
        // edit grows it to pushable size it must re-enter the push queue.
        if session.pushedToOP, session.opTimeEntryID == nil,
           session.end.timeIntervalSince(session.start) >= 60 {
            session.pushedToOP = false
        }
        try? journal.update(session)
        if case .op(let wpID) = session.task, let entryID = session.opTimeEntryID,
           let client {
            do {
                try await client.updateTimeEntry(
                    id: entryID, workPackageID: wpID, start: session.start,
                    duration: session.end.timeIntervalSince(session.start),
                    activityID: settings.activityOverrides[session.task] ?? settings.defaultActivityID,
                    comment: session.comment,
                    startTime: Self.iso8601.string(from: session.start))
                DebugLog.write("timeline edit pushed to OP entry \(entryID)")
            } catch {
                lastError = "OP update failed: \(error)"
            }
        } else if previous?.task != session.task {
            await syncIfEnabled()   // reassigned: push under the new task
        }
        updateJournalSummary()
    }

    /// The longest focus span inside a session — the surface that dominated it,
    /// for teaching a durable window→task (or →don't-track) association.
    private func dominantSpan(of session: Session) -> FocusSpan? {
        ((try? journal.spans(from: session.start, to: session.end)) ?? [])
            .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
    }

    /// Teach the attributor the dominant surface→task association inside a
    /// reassigned session, so future time on that window stops mis-filing.
    private func teachAssociation(for session: Session) {
        guard let dominant = dominantSpan(of: session) else { return }
        attributor.assign(dominant.signal, target: .task(session.task))
        persistAssociations()
    }

    /// "Don't track this": drop the slice's tracked time (and any OP entry) but
    /// keep its window detail, and teach the attributor its dominant surface is
    /// non-work so similar time stops auto-tracking. Undo restores the slice.
    /// Used to undo e.g. an away stretch you didn't actually work.
    public func markSessionDoNotTrack(_ session: Session) async {
        if let dominant = dominantSpan(of: session) {
            attributor.assign(dominant.signal, target: .doNotTrack)
            persistAssociations()
        }
        await deleteTimelineSession(session)
    }

    public func deleteTimelineSession(_ session: Session, undoable: Bool = true) async {
        if undoable {
            var restore = session
            restore.opTimeEntryID = nil
            restore.pushedToOP = false   // re-push on restore
            registerUndo("delete \(name(of: .task(session.task)))") { [weak self] in
                guard let self else { return }
                try? self.journal.save(restore)
                self.updateJournalSummary()
                await self.syncIfEnabled()
            }
        }
        try? journal.deleteSession(session.id)
        if let entryID = session.opTimeEntryID, let client {
            try? await client.deleteTimeEntry(id: entryID)
        }
        updateJournalSummary()
    }

    public func reassignTimelineSessions(_ sessions: [Session], to task: TaskRef,
                                          undoable: Bool = true) async {
        if undoable {
            let originals = sessions.filter { $0.id != Self.liveSessionID }
            registerUndo("reassign \(originals.count) slices") { [weak self] in
                guard let self else { return }
                // restore each to its original task
                for original in originals {
                    await self.reassignTimelineSessions(
                        (try? self.journal.allSessions())?.filter { $0.id == original.id } ?? [],
                        to: original.task, undoable: false)
                }
            }
        }
        for var session in sessions where session.id != Self.liveSessionID {
            // Re-creating under the new task is simpler and more reliable than
            // PATCHing the work-package link.
            if let entryID = session.opTimeEntryID, let client {
                try? await client.deleteTimeEntry(id: entryID)
            }
            session.task = task
            session.opTimeEntryID = nil
            session.pushedToOP = false
            try? journal.update(session)
            teachAssociation(for: session)   // stop the same window mis-filing again
        }
        await syncIfEnabled()
    }

    /// One-line feedback for the Spent view (also forces a refresh since it
    /// is @Published — the pie reads the journal, which the reassign changed).
    @Published public private(set) var actionNote: String?

    /// Move time spent in app `appLabel` to `target` across a period — by
    /// SPLITTING each session at that app's window spans (the Games time is
    /// usually a minor slice of a larger task's sessions, so whole-session
    /// matching found nothing). Teaches the attributor so it stops recurring.
    public func reassignSpentApp(_ appLabel: String, from: Date, to: Date,
                                 to target: TaskRef) async {
        let candidates = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.task != target }
        var work: [(Session, [Session])] = []
        var movedSeconds: TimeInterval = 0
        for session in candidates {
            let spans = ((try? journal.spans(from: session.start, to: session.end)) ?? [])
                .filter { $0.signal.app == appLabel }
            guard !spans.isEmpty else { continue }
            let ranges = spans.map {
                (start: max($0.start, session.start), end: min($0.end, session.end))
            }
            let pieces = TimelineMath.split(session, reassign: ranges, to: target)
            let moved = pieces.filter { $0.task == target }
            guard !moved.isEmpty else { continue }
            movedSeconds += moved.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            work.append((session, pieces))
        }
        guard !work.isEmpty else {
            actionNote = "No \(appLabel) windows recorded in this period to move"
            return
        }
        await undoGroup("move \(appLabel) → \(name(of: .task(target)))") {
            for (session, pieces) in work { await replaceSession(session, with: pieces) }
        }
        actionNote = "Moved \(MenuTitle.text(elapsed: movedSeconds, certainty: nil, showPercent: false)) of \(appLabel) → \(name(of: .task(target)))"
    }

    private var coalescing = false
    /// Serialises sync: `syncIfEnabled` is fired from many places (every slice
    /// flush, the 60 s timer, every timeline edit). Without this, two overlapping
    /// runs both fetch the same unpushed session across their network `await` and
    /// both POST it — the duplicate-OP-entry bug. `syncRequested` runs one more
    /// pass if a trigger arrived mid-sync, so nothing eligible is missed.
    private var syncing = false
    private var syncRequested = false

    /// Merge same-task sessions that now butt up against each other (after an
    /// edit/drag) into one, without losing data. Direct journal+OP cleanup,
    /// guarded against re-entry.
    public func coalesceAdjacent(around date: Date) async {
        guard !coalescing else { return }
        coalescing = true
        defer { coalescing = false }
        // A window AROUND the edit point, not the calendar day — so two same-
        // task slices straddling midnight (23:50–00:20) still fold into one.
        // Bounded (±12 h) so it never becomes a full-history scan.
        let from = date.addingTimeInterval(-12 * 3600)
        let to = date.addingTimeInterval(12 * 3600)
        let original = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }   // never fold the crash-safety row
        let merged = TimelineMath.mergeAdjacent(original)
        guard merged.count != original.count else { return }
        let survivors = Set(merged.map(\.id))
        for o in original where !survivors.contains(o.id) {
            try? journal.deleteSession(o.id)
            if let e = o.opTimeEntryID, let client { try? await client.deleteTimeEntry(id: e) }
        }
        for m in merged where original.first(where: { $0.id == m.id }) != m {
            var survivor = m
            // The survivor keeps the earliest slice's id (and OP entry). If that
            // entry already exists on OP, rewrite it IN PLACE to the merged
            // extent — `pushEligible` only ever *creates*, so a re-push would
            // duplicate the log. Patch + mark handled; leave only never-pushed
            // survivors for sync to create fresh.
            if case .op(let wpID) = survivor.task, let entryID = survivor.opTimeEntryID,
               let client {
                do {
                    try await client.updateTimeEntry(
                        id: entryID, workPackageID: wpID, start: survivor.start,
                        duration: survivor.end.timeIntervalSince(survivor.start),
                        activityID: settings.activityOverrides[survivor.task] ?? settings.defaultActivityID,
                        comment: survivor.comment,
                        startTime: Self.iso8601.string(from: survivor.start))
                    survivor.pushedToOP = true   // updated in place; don't re-create
                    DebugLog.write("coalesce patched OP entry \(entryID)")
                } catch {
                    // Keep it handled rather than risk a duplicate; the stale
                    // entry can be re-synced by a later edit.
                    survivor.pushedToOP = true
                    lastError = "OP merge-update failed: \(error)"
                }
            }
            try? journal.update(survivor)
        }
        await syncIfEnabled()
        updateJournalSummary()
        DebugLog.write("coalesced \(original.count) → \(merged.count) sessions")
    }

    /// Replace a session with split pieces (delete original + OP entry,
    /// create each piece, teach moved pieces). Caller wraps in an undo group.
    private func replaceSession(_ session: Session, with pieces: [Session]) async {
        await deleteTimelineSession(session)
        for piece in pieces { await createTimelineSession(piece) }
        for piece in pieces where piece.task != session.task { teachAssociation(for: piece) }
    }

    /// Split a slice: the given time ranges (selected windows in the detail
    /// strip) move to `target`, the rest stays. One undo step.
    public func splitAndReassign(_ session: Session,
                                 ranges: [(start: Date, end: Date)],
                                 to target: TaskRef) async {
        let pieces = TimelineMath.split(session, reassign: ranges, to: target)
        guard pieces.count > 1 || pieces.first?.task != session.task else { return }
        await undoGroup("split \(name(of: .task(session.task)))") {
            await replaceSession(session, with: pieces)
        }
    }

    /// Reassign a whole task's period sessions to another task.
    public func reassignSpentTask(_ ref: TaskRef, from: Date, to: Date,
                                  to target: TaskRef) async {
        let sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.task == ref }
        await reassignTimelineSessions(sessions, to: target)
        actionNote = sessions.isEmpty
            ? "No time found to move"
            : "Moved \(sessions.count) session\(sessions.count == 1 ? "" : "s") → \(name(of: .task(target)))"
    }

    // MARK: - AI assist (clipboard out, paste back)

    public func copyAIPrompt() {
        let prompt = AIAssist.classificationPrompt(tasks: taskCache, segments: pendingReview)
        copyToClipboard(prompt)
    }

    /// Put a string on the general pasteboard (the AI-assist flows copy a prompt
    /// for the user to paste into the AI of their choice).
    public func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The raw app / title / url of the current focus surface — the fields the
    /// AI pin prompt is built from. nil when there's nothing focused.
    public func currentSurfaceFields() -> (app: String, title: String?, url: String?)? {
        guard let s = tracker.currentFocusSignal else { return nil }
        return (s.app, s.windowTitle, s.tabURL)
    }

    /// Dev diagnostic: probe the front browser's AX tree for sender candidates,
    /// format a report, and copy it to the clipboard. Drives the email-sender
    /// signal design (TODO 2026-06-29).
    public func probeEmailSender() -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibility permission not granted — System Settings ▸ Privacy ▸ Accessibility."
        }
        guard let r = EmailSignalProbe.probeFrontBrowser() else {
            return "No running browser found (Chrome / Opera / Brave / Safari)."
        }
        var out = "Browser: \(r.app)\nNodes scanned: \(r.nodesScanned)\(r.truncated ? " (capped)" : "")\n"
        if r.nodesScanned < 200 {
            out += "(Looks like only the window chrome — Chrome's page accessibility " +
                   "tree may still be building. Click Probe again in a second.)\n"
        }
        out += "\nEmail addresses found (\(r.candidates.count)):\n"
        out += r.candidates.isEmpty ? "  (none)\n"
            : r.candidates.map { "  • \($0)" }.joined(separator: "\n") + "\n"
        out += "\nNodes containing '@' (role | text):\n"
        out += r.contexts.isEmpty ? "  (none)"
            : r.contexts.map { "  \($0)" }.joined(separator: "\n")
        // The real channel: detect the system + run its DOM recipe.
        out += "\n\n— Recipe channel (page JavaScript) —\n"
        if let p = EmailSignalProbe.frontBrowserParties() {
            out += "System: \(p.system.rawValue)\n"
            if let e = p.error { out += "Error: \(e)\n" }
            func fmt(_ ps: [EmailSignal.Party]) -> String {
                ps.isEmpty ? "(none)" : ps.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ")
            }
            out += "Sender: \(fmt(p.senders))\n"
            out += "Recipients: \(fmt(p.recipients))\n"
            let others = EmailSignal.counterparties(senders: p.senders, recipients: p.recipients)
            out += "Counterparties (you removed): \(fmt(others))\n"
            let domains = Set(others.compactMap { EmailSignal.domain(of: $0.email) })
                .sorted().joined(separator: ", ")
            out += "Counterparty domains: \(domains.isEmpty ? "(none)" : domains)"
        } else {
            out += "Front app is not a supported browser."
        }
        copyToClipboard(out)
        return out
    }

    public func ingestAIResponse(_ raw: String) -> String {
        do {
            let assignments = try AIAssist.parseResponse(
                raw, validSegmentIDs: Set(pendingReview.map(\.id)))
            for a in assignments {
                assignReview([a.segmentID], to: a.target)
            }
            return "Applied \(assignments.count) assignments."
        } catch {
            return "Rejected: \(error)"
        }
    }

    // MARK: - OP

    public func saveAPIKey(_ key: String) {
        do {
            try APIKeyStore.saveAPIKey(key)
        } catch {
            lastError = "API key save failed – \(error)"
            return
        }
        reconnect()
    }

    /// Reconnect using the already-stored API key — e.g. after re-entering only
    /// the instance URL (the key lives in its own file and need not be retyped).
    public func reconnect() {
        rebuildClient()
        Task { await refreshTasks() }
    }

    /// True when an API key is already on disk, so the UI can offer "Connect"
    /// without forcing a re-entry.
    public func hasStoredAPIKey() -> Bool {
        (try? APIKeyStore.loadAPIKey())?.isEmpty == false
    }

    public func refreshTasks() async {
        guard let client else {
            if lastError == nil, !settings.opBaseURL.isEmpty {
                lastError = "Not connected – check OP URL and API key in Settings"
            }
            return
        }
        do {
            if connectedAs == nil {
                connectedAs = try? await client.fetchMe()
            }
            // Carry recency over the refresh: lastConfirmedAt lives only in
            // the cache and a wholesale replace was silently dropping it.
            let recency = Dictionary(uniqueKeysWithValues:
                taskCache.compactMap { task in task.lastConfirmedAt.map { (task.ref, $0) } })
            var fetched = try await client.fetchTasks()
            for i in fetched.indices {
                if let last = recency[fetched[i].ref] {
                    fetched[i].lastConfirmedAt = max(fetched[i].lastConfirmedAt ?? .distantPast, last)
                }
            }
            taskCache = fetched + localWorkTasks().map { local in
                var task = local
                task.lastConfirmedAt = recency[local.ref]
                return task
            }
            applyJournalRecency()   // durable recency, not just this session's

            if activities.isEmpty {
                activities = (try? await client.fetchActivities()) ?? []
                if settings.defaultActivityID == nil {
                    settings.defaultActivityID = activities.first?.id
                }
            }
            lastError = nil
        } catch {
            lastError = "OP fetch failed: \(error)"
        }
    }

    public func syncIfEnabled() async {
        guard let client else { return }
        // Non-reentrant: if a push is already in flight, just ask it to run once
        // more when it finishes (a concurrent run would re-POST the same session
        // across its network await — duplicate OP entries).
        if syncing { syncRequested = true; return }
        syncing = true
        defer { syncing = false }
        let engine = SyncEngine(journal: journal, client: client)
        engine.onDebug = { DebugLog.write("sync: \($0)") }
        repeat {
            syncRequested = false
            do {
                let pushed = try await engine.pushEligible(
                    threshold: settings.certaintyAutoPushThreshold,
                    defaultActivityID: settings.defaultActivityID,   // nil = OP's default
                    activityOverrides: settings.activityOverrides,
                    includeComments: settings.autoComment)
                if pushed > 0 { DebugLog.write("pushed \(pushed) entries to OP") }
                if !engine.startTimesSupported {
                    lastError = "OP rejected start times – entries pushed date-only (check Administration → Time and costs → start/end times)"
                }
            } catch {
                lastError = "OP push failed: \(error)"
            }
        } while syncRequested
        updateJournalSummary()
    }
}

/// Notifications when running as a real .app bundle; silent no-op otherwise
/// (UNUserNotificationCenter requires a bundle identifier).
/// Last-words crash logging: the app has died "for no apparent reason" more
/// than once; these traps write the cause into the debug log before dying.
/// (Not strictly async-signal-safe — best-effort forensics, not correctness.)
func installCrashTraps() {
    NSSetUncaughtExceptionHandler { exception in
        DebugLog.write("CRASH NSException \(exception.name.rawValue): \(exception.reason ?? "?")\n"
            + exception.callStackSymbols.prefix(10).joined(separator: "\n"))
    }
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
        signal(sig) { s in
            DebugLog.write("CRASH signal \(s)\n"
                + Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
            exit(128 + s)
        }
    }
}

/// Diagnostic event log at a world-readable path so remote debugging over the
/// scoped SSH user works (the agent cannot read Martin's home). Window titles
/// appear in it; delete the file to clear, toggle by removing write access.
enum DebugLog {
    static let path = "/Users/Shared/ambitick-debug.log"
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

/// Self-drawn floating banner. Deliberately NO system notification API:
/// UNUserNotificationCenter aborts the process on code-identity churn and
/// NSUserNotification is dead on modern macOS (never displayed, crashed on
/// delivery) — both bitten us. A floating panel needs no permissions and
/// cannot take the app down.
enum Notifier {
    /// Wired to AmbitickSettings.systemNotifications; sounds still play when off.
    static var enabled = true
    private static var panel: NSPanel?
    private static var dismissTask: DispatchWorkItem?

    static func requestAuthorization() {}

    /// `symbol` is an SF Symbol name drawn as the leading glyph (the "logo"),
    /// so a task change reads as "→ Ambitick" rather than the slow-to-read
    /// "Task changed — Ambitick". Falls back to text only if the symbol is
    /// unavailable.
    static func notify(symbol: String?, text: String, sound: String) {
        DispatchQueue.main.async {
            NSSound(named: sound)?.play()
            guard enabled else { return }
            showBanner(symbol: symbol, text: text)
        }
    }

    /// Back-compat text-only entry point.
    static func notify(title: String, body: String, sound: String) {
        notify(symbol: nil, text: "\(title) — \(body)", sound: sound)
    }

    private static func showBanner(symbol: String?, text: String) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        guard let screen = NSScreen.main else { return }

        let padding: CGFloat = 14
        let iconSize: CGFloat = 17
        let gap: CGFloat = 8

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()

        var iconView: NSImageView?
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            view.symbolConfiguration = .init(pointSize: iconSize, weight: .semibold)
            iconView = view
        }

        let iconSpace = iconView == nil ? 0 : iconSize + gap
        let textWidth = min(label.frame.width, 360)
        let width = padding * 2 + iconSpace + textWidth
        let height = max(label.frame.height, iconSize) + padding * 1.2
        let rect = NSRect(x: screen.visibleFrame.maxX - width - 16,
                          y: screen.visibleFrame.maxY - height - 12,
                          width: width, height: height)

        let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10

        if let iconView {
            iconView.frame = NSRect(x: padding, y: (height - iconSize) / 2,
                                    width: iconSize, height: iconSize)
            background.addSubview(iconView)
        }
        label.frame = NSRect(x: padding + iconSpace, y: (height - label.frame.height) / 2,
                             width: textWidth, height: label.frame.height)
        background.addSubview(label)
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        let task = DispatchWorkItem { panel?.orderOut(nil); panel = nil }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }
}

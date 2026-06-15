import Foundation
import AppKit
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

/// Owns the whole pipeline: sensors -> tracker -> journal -> sync, plus the
/// published state the SwiftUI layer renders.
@MainActor
public final class AppController: ObservableObject {
    @Published public private(set) var trackerState: TrackerState = .stopped
    @Published public private(set) var menuText = "–"
    @Published public private(set) var menuColour = NSColor.systemGray
    @Published public private(set) var taskCache: [WorkTask] = []
    @Published public private(set) var pendingReview: [ReviewSegment] = []
    @Published public private(set) var activities: [OPTimeActivity] = []
    @Published public private(set) var lastPrompt: TrackerPrompt?
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
            if oldValue.opBaseURL != settings.opBaseURL { rebuildClient() }
        }
    }

    public let journal: any JournalStore
    private let attributor: Attributor
    private var tracker: SessionTracker!
    private let sensors = SensorHub()
    private let settingsStore: JSONFileStore<AmbitickSettings>
    private let learningStore: JSONFileStore<LearningStore>
    private let primedStore: JSONFileStore<[Surface: TaskRef]>
    private var client: OPClient?
    private var titleTimer: Timer?
    private var taskRefreshTimer: Timer?
    private var taskChangedAt = Date()
    private var currentTarget: Target?
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

        let leisure = loadedSettings.localTasks.first(where: \.isLeisure)
            .map { TaskRef.local($0.id) }
        let config = TrackerConfig(
            minSegmentSeconds: loadedSettings.minSegmentSeconds,
            primeDwellSeconds: loadedSettings.primeDwellSeconds,
            idleThresholdSeconds: PowerSettings.displaySleepSeconds() ?? 600,
            nonWorkTracksLocally: loadedSettings.trackLeisureLocally && leisure != nil,
            leisureTask: leisure,
            switchGraceSeconds: loadedSettings.switchGraceSeconds)
        tracker = SessionTracker(attributor: attributor, config: config) { [weak self] in
            self?.taskCache ?? []
        }
        wireTracker()
        rebuildClient()
        taskCache = localWorkTasks()   // locals exist before OP ever connects
    }

    /// User-defined non-OP tasks rendered as first-class tasks.
    private func localWorkTasks() -> [WorkTask] {
        settings.localTasks.map {
            WorkTask(ref: .local($0.id), subject: $0.name, project: "Personal",
                     status: $0.isLeisure ? "Leisure" : "Open")
        }
    }

    @discardableResult
    public func addLocalTask(name: String, isLeisure: Bool) -> TaskRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse an existing local task of the same name instead of duplicating.
        if let existing = settings.localTasks.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .local(existing.id)
        }
        let def = LocalTaskDef(name: trimmed, isLeisure: isLeisure)
        settings.localTasks.append(def)
        mergeLocalTasksIntoCache()
        registerUndo("add local task \(trimmed)") { [weak self] in
            self?.removeLocalTask(def.id, undoable: false)
        }
        return .local(def.id)
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

    private func mergeLocalTasksIntoCache() {
        let known = Set(taskCache.map(\.ref))
        for task in localWorkTasks() where !known.contains(task.ref) {
            taskCache.append(task)
        }
    }

    private func wireTracker() {
        tracker.onSession = { [weak self] session in
            guard let self else { return }
            var s = session
            if !self.manualNote.isEmpty {
                s.comment = self.manualNote   // the speech-bubble note wins
            } else if !self.settings.autoComment {
                s.comment = nil
            }
            try? self.journal.save(s)
            // Tracked time counts as recency: the task you just worked on
            // belongs at the top of every pick list.
            if let i = self.taskCache.firstIndex(where: { $0.ref == s.task }) {
                self.taskCache[i].lastConfirmedAt = s.end
            }
            self.updateJournalSummary()
            Task { await self.syncIfEnabled() }
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
                    self.currentTarget = target
                    self.targetSince = now
                    self.visitSolid = false
                    self.taskChangedAt = now
                    // The note describes the task just left (already attached
                    // to its flushed session above); clear it so it doesn't
                    // bleed onto the new task.
                    self.manualNote = ""
                }
            } else {
                self.currentTarget = nil
                self.targetSince = nil
                self.visitSolid = false
                self.bankedElapsed.removeAll()
                self.manualNote = ""
                self.taskChangedAt = now
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
            case .resumeAfterIdle:
                Notifier.notify(symbol: "sun.max", text: "Welcome back — work continued?",
                                sound: "Tink")
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
            key = try KeychainStore.loadAPIKey()
        } catch {
            lastError = "Cannot read API key – \(error). Re-enter and Save."
            return
        }
        guard let key else {
            lastError = "No API key stored yet – enter it below and Save"
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
                await self?.refreshTasks()
                await self?.syncIfEnabled()   // retry path for failed/late pushes
            }
        }
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
            let running = targetSince.map { Date().timeIntervalSince($0) } ?? 0
            // When THIS task's current visit survives the grace it has "taken
            // over": every OTHER task's session is now ended (a real stint
            // elsewhere starts fresh on return). Brief excursions never reach
            // here, so they leave the other accumulators intact — the clock
            // shows the current contiguous session, i.e. what would post to OP.
            if !visitSolid, running >= settings.switchGraceSeconds {
                visitSolid = true
                bankedElapsed = bankedElapsed.filter { $0.key == target }
            }
            let elapsed = bankedElapsed[target, default: 0] + running
            newText = MenuTitle.text(elapsed: elapsed, certainty: certainty,
                                     showPercent: settings.showPercent)
            newColour = MenuTitle.colour(certainty: certainty, lowHex: settings.colourLow,
                                         highHex: settings.colourHigh)
        }
        if force || newText != menuText { menuText = newText }
        if force || !newColour.isEqual(menuColour) { menuColour = newColour }
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

    public func pickList() -> [WorkTask] {
        TaskRanker(config: RankingConfig(statusOrder: settings.statusOrder,
                                         currentUser: connectedAs))
            .pickList(taskCache, at: Date(), recentCount: settings.recentCount,
                      likelyCount: settings.likelyCount, learning: attributor.learning)
    }

    /// Pick list first (N recent + M likely), then every remaining task in
    /// ranked order — every list is scrollable to the full task set.
    public func fullPickList() -> [WorkTask] {
        let ranker = TaskRanker(config: RankingConfig(statusOrder: settings.statusOrder,
                                                      currentUser: connectedAs))
        let top = pickList()
        let topRefs = Set(top.map(\.ref))
        let rest = ranker.ranked(taskCache.filter { !topRefs.contains($0.ref) },
                                 at: Date(), learning: attributor.learning)
        return top + rest
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
    }

    public func userStopped() {
        if away { away = false; tracker.away = false }
        scheduledStop = nil
        tracker.stop(at: Date())
    }

    /// "Change to": relabel the RUNNING session to `ref`, keeping its elapsed
    /// time (the mis-attributed time moves to the right task, the clock does
    /// not reset). Distinct from userPicked, which starts a fresh session.
    public func changeCurrentTask(to ref: TaskRef) {
        guard case .tracking(let oldTarget, _) = trackerState, .task(ref) != oldTarget else { return }
        let now = Date()
        let elapsed = (bankedElapsed[oldTarget] ?? 0)
            + (targetSince.map { now.timeIntervalSince($0) } ?? 0)
        let keptNote = manualNote
        tracker.relabelCurrentSession(to: ref)   // re-tags spans; fires onState
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

    public func assignReview(_ ids: [UUID], to target: Target, undoable: Bool = true) {
        if undoable {
            let learningSnapshot = attributor.learning
            let primedSnapshot = attributor.primedSurfaces
            registerUndo("assign \(ids.count) review rows") { [weak self] in
                guard let self else { return }
                try? self.journal.assign(ids, to: nil)
                self.attributor.replaceLearning(learningSnapshot)
                self.attributor.primedSurfaces = primedSnapshot
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

    private func updateJournalSummary() {
        let all = (try? journal.allSessions()) ?? []
        let awaiting = (try? journal.sessions(
            needingPushAtOrAbove: settings.certaintyAutoPushThreshold).count) ?? 0
        let pushed = all.filter(\.pushedToOP).count
        journalSummary = "\(all.count) sessions journalled · \(pushed) handled · \(awaiting) awaiting push"
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

    // MARK: - Timeline

    /// Sessions overlapping the given day (0 = today, -1 = yesterday, ...),
    /// plus a synthetic live slice for the current visit when tracking.
    public func timelineSessions(dayOffset: Int) -> [Session] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: dayOffset,
                                                              to: Date()) ?? Date())
        let dayEnd = dayStart.addingTimeInterval(86_400)
        var list = (try? journal.sessions(from: dayStart, to: dayEnd)) ?? []
        if dayOffset == 0, case .tracking(.task(let ref), let certainty) = trackerState,
           let since = targetSince {
            list.append(Session(id: Self.liveSessionID, task: ref, start: since,
                                end: Date(), certainty: certainty))
        }
        return list
    }

    public static let liveSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!

    public func timelineSpans(for session: Session) -> [FocusSpan] {
        (try? journal.spans(from: session.start, to: session.end)) ?? []
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

    /// Time Spent hierarchy for the pie: project -> task -> app, including
    /// the live session when the range covers now. Sessions crossing the
    /// range boundary are clipped so totals never double-count across days.
    public func spentNodes(from: Date, to: Date) -> [TimeAggregator.Node] {
        var sessions = ((try? journal.sessions(from: from, to: to)) ?? []).map { s -> Session in
            var c = s
            c.start = max(s.start, from)
            c.end = min(s.end, to)
            return c
        }
        if case .tracking(.task(let ref), let certainty) = trackerState,
           let since = targetSince, since < to, Date() > from {
            sessions.append(Session(id: Self.liveSessionID, task: ref,
                                    start: max(since, from), end: min(Date(), to),
                                    certainty: certainty))
        }
        let spans = (try? journal.spans(from: from, to: to)) ?? []
        return TimeAggregator.byProject(sessions: sessions, tasks: taskCache, spans: spans)
    }

    /// Timeline edit of the live slice's start.
    public func adjustLiveStart(to date: Date) {
        let clamped = min(date, Date())
        tracker.adjustCurrentStart(to: clamped)
        targetSince = clamped
        refreshTitle(force: true)
    }

    /// The most recently tracked task today — the obvious resume candidate.
    public func lastTrackedTask() -> WorkTask? {
        let dayStart = Calendar.current.startOfDay(for: Date())
        guard let last = (try? journal.sessions(from: dayStart, to: Date()))?.last else {
            return nil
        }
        return taskCache.first { $0.ref == last.task }
    }

    /// A brand-new manual slice (drawn or gap-filled on the timeline).
    public func createTimelineSession(_ session: Session) async {
        try? journal.save(session)
        registerUndo("create \(name(of: .task(session.task)))") { [weak self] in
            guard let self else { return }
            let saved = (try? self.journal.allSessions())?.first { $0.id == session.id }
            await self.deleteTimelineSession(saved ?? session, undoable: false)
        }
        updateJournalSummary()
        await syncIfEnabled()
    }

    /// Persist a timeline edit; PATCH the OP entry when one exists.
    public func applyTimelineEdit(_ session: Session, undoable: Bool = true) async {
        if undoable,
           let previous = (try? journal.allSessions())?.first(where: { $0.id == session.id }) {
            registerUndo("edit \(name(of: .task(previous.task)))") { [weak self] in
                await self?.applyTimelineEdit(previous, undoable: false)
            }
        }
        var session = session
        let previous = (try? journal.allSessions())?.first(where: { $0.id == session.id })
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
                    startTime: ISO8601DateFormatter().string(from: session.start))
                DebugLog.write("timeline edit pushed to OP entry \(entryID)")
            } catch {
                lastError = "OP update failed: \(error)"
            }
        } else if previous?.task != session.task {
            await syncIfEnabled()   // reassigned: push under the new task
        }
        updateJournalSummary()
    }

    /// Teach the attributor the dominant surface→task association inside a
    /// reassigned session, so future time on that window stops mis-filing.
    private func teachAssociation(for session: Session) {
        let spans = (try? journal.spans(from: session.start, to: session.end)) ?? []
        guard let dominant = spans.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }) else { return }
        attributor.assign(dominant.signal, target: .task(session.task))
        try? learningStore.save(attributor.learning)
        try? primedStore.save(attributor.primedSurfaces)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
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
            try KeychainStore.saveAPIKey(key)
        } catch {
            lastError = "API key save failed – \(error)"
            return
        }
        rebuildClient()
        Task { await refreshTasks() }
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
        let engine = SyncEngine(journal: journal, client: client)
        engine.onDebug = { DebugLog.write("sync: \($0)") }
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

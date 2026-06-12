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
    @Published public var manualNote = ""
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
    /// Per-task visible clocks: a momentary switch shows the new task's
    /// accumulated time immediately, and returning restores the old clock.
    /// Flash visits (< switch grace) don't credit the flashed task — their
    /// seconds go to `limbo` and merge into the next task that holds focus
    /// solidly, matching the dominant-minute ledger. Cleared on stop.
    private var bankedElapsed: [Target: TimeInterval] = [:]
    private var targetSince: Date?
    private var visitSolid = false
    private var limbo: TimeInterval = 0

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

    public func addLocalTask(name: String, isLeisure: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let def = LocalTaskDef(name: trimmed, isLeisure: isLeisure)
        settings.localTasks.append(def)
        mergeLocalTasksIntoCache()
        registerUndo("add local task \(trimmed)") { [weak self] in
            self?.removeLocalTask(def.id, undoable: false)
        }
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
                    // Bank the outgoing visit — to the task if it was a solid
                    // stay, to limbo if it was a flash-through.
                    if let old = self.currentTarget, let since = self.targetSince {
                        let visit = now.timeIntervalSince(since)
                        if self.visitSolid || visit >= self.settings.switchGraceSeconds {
                            self.bankedElapsed[old, default: 0] += visit
                        } else {
                            self.limbo += visit
                        }
                    }
                    self.currentTarget = target
                    self.targetSince = now
                    self.visitSolid = false
                    self.taskChangedAt = now
                }
            } else {
                self.currentTarget = nil
                self.targetSince = nil
                self.visitSolid = false
                self.limbo = 0
                self.bankedElapsed.removeAll()
                self.manualNote = ""
                self.taskChangedAt = now
                Notifier.notify(title: "Timer stopped", body: "Ambitick stopped the clock.",
                                sound: "Basso")
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
                Notifier.notify(title: "Task changed",
                                body: self.name(of: target), sound: "Tink")
            case .resumeAfterIdle:
                Notifier.notify(title: "Welcome back",
                                body: "Did work continue, or was the stop time correct?",
                                sound: "Tink")
            case .callEnded:
                Notifier.notify(title: "Call ended",
                                body: "Assign the call, or choose Do not track.",
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
            Task { @MainActor in self?.refreshTitle(force: false) }
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
            // A visit that survives the grace becomes solid: it absorbs any
            // flash-through seconds AND ends every other task's session — the
            // clock shows the current contiguous session, not a daily total
            // (a real stint elsewhere means returning starts at 0s; only
            // flashes preserve the running clock).
            if !visitSolid, running >= settings.switchGraceSeconds {
                visitSolid = true
                bankedElapsed = bankedElapsed.filter { $0.key == target }
                bankedElapsed[target, default: 0] += limbo
                limbo = 0
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
        tracker.stop(at: Date())
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

    private func registerUndo(_ label: String, inverse: @escaping () async -> Void) {
        undoStack.append((label, inverse))
        undoCount = undoStack.count
    }

    public func undo() {
        guard let last = undoStack.popLast() else {
            NSSound(named: "Funk")?.play()
            return
        }
        undoCount = undoStack.count
        Notifier.notify(title: "Undo", body: last.label, sound: "Pop")
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
        }
        updateJournalSummary()
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
        }
        await syncIfEnabled()
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

    static func notify(title: String, body: String, sound: String) {
        DispatchQueue.main.async {
            NSSound(named: sound)?.play()
            guard enabled else { return }
            showBanner("\(title) — \(body)")
        }
    }

    private static func showBanner(_ text: String) {
        dismissTask?.cancel()
        panel?.close()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()

        let padding: CGFloat = 14
        let width = min(label.frame.width + padding * 2, 420)
        let height = label.frame.height + padding * 1.2
        guard let screen = NSScreen.main else { return }
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

        let background = NSVisualEffectView(frame: NSRect(origin: .zero,
                                                          size: rect.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: padding, y: (height - label.frame.height) / 2)
        label.frame.size.width = width - padding * 2
        background.addSubview(label)
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        let task = DispatchWorkItem { panel?.close(); panel = nil }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }
}

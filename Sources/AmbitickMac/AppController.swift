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

        let config = TrackerConfig(
            minSegmentSeconds: loadedSettings.minSegmentSeconds,
            primeDwellSeconds: loadedSettings.primeDwellSeconds,
            idleThresholdSeconds: PowerSettings.displaySleepSeconds() ?? 600,
            nonWorkTracksLocally: loadedSettings.trackLeisureLocally,
            leisureTask: loadedSettings.trackLeisureLocally ? .local(UUID()) : nil,
            switchGraceSeconds: loadedSettings.switchGraceSeconds)
        tracker = SessionTracker(attributor: attributor, config: config) { [weak self] in
            self?.taskCache ?? []
        }
        wireTracker()
        rebuildClient()
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
            // A visit that survives the grace becomes solid and absorbs any
            // flash-through seconds accumulated in limbo.
            if !visitSolid, running >= settings.switchGraceSeconds {
                visitSolid = true
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

    public func assignReview(_ ids: [UUID], to target: Target) {
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
            taskCache = try await client.fetchTasks()
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

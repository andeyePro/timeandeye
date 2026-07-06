import Foundation
import Combine
import andeyeTTCore
import andeyeTTStore

/// The iOS app's engine. iOS senses no other apps — ever — so this is the
/// SECOND SCREEN + MANUAL TRACKER: show what's tracked, switch with one tap,
/// record manual slices. It reuses the Mac's Core wholesale: same journal
/// store, same ranker, same backends (OP works fully over the network), same
/// timesheet export. CloudKit sync joins once the entitled build exists —
/// until then the phone journal is standalone (and fully local-first after).
///
/// Lives in the package (not ios/) so the CLT-only Mac loop compile-guards
/// it and the check suite drives it — only the SwiftUI shell in ios/ waits
/// for a machine with Xcode. UI-framework-free by design (Combine only).
@MainActor
public final class PhoneController: ObservableObject {
    @Published public private(set) var taskCache: [WorkTask] = []
    @Published public private(set) var tracking: (task: TaskRef, since: Date)?
    @Published public private(set) var connectedAs: String?
    @Published public private(set) var lastError: String?
    @Published public var settings: AndeyeSettings {
        didSet {
            try? settingsStore.save(settings)
            if oldValue.opBaseURL != settings.opBaseURL { rebuildBackend() }
            if oldValue.localTasks != settings.localTasks { mergeLocalTasks() }
        }
    }

    public let journal: any JournalStore
    private let settingsStore: JSONFileStore<AndeyeSettings>
    private var backend: (any TaskBackend)?
    private let ranker = TaskRanker()

    /// The clock, injectable so checks can cross the 30-second slice
    /// threshold without waiting. The app never touches it.
    let now: () -> Date

    public init(dataDir: URL = AppSupport.directory(), now: @escaping () -> Date = Date.init) {
        self.now = now
        let dir = dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsStore = JSONFileStore<AndeyeSettings>(
            url: dir.appendingPathComponent("settings.json"))
        settings = (try? settingsStore.load().flatMap { $0 })
            ?? AndeyeSettings(opBaseURL: "")
        journal = (try? SQLiteJournalStore(path: dir.appendingPathComponent("journal.sqlite").path))
            ?? InMemoryJournalStore()
        // Same one-time single-slot → posting-ledger upgrade as the Mac (this
        // journal pushed with the same legacy fields); idempotent per row.
        try? journal.migrateSingleSlotPostings(to: OPBackend.stableID,
                                               excluding: [Self.liveCheckpointID])
        restoreLiveSlice()
        mergeLocalTasks()
        rebuildBackend()
        Task { await refreshTasks() }
    }

    // MARK: - Manual tracking (the whole point on iOS)

    /// A running manual slice survives app death via the same crash-checkpoint
    /// pattern as the Mac (fixed id, promoted on next launch).
    public static let liveCheckpointID = UUID(uuidString: "00000000-0000-0000-0000-0000C0FFEE01")!

    public func start(_ task: TaskRef) {
        if tracking?.task == task { return }   // tapping the tracked task: no-op
        if tracking != nil { stop() }          // switching = stop + start
        tracking = (task, now())
        touchRecency(task)
        checkpoint()
    }

    /// "That timer was really this task": move the RUNNING slice onto `task`
    /// keeping its start time — no slice is banked, no new one starts. The
    /// crash checkpoint follows so a relaunch resumes under the new label.
    public func relabelCurrent(to task: TaskRef) {
        guard let live = tracking, live.task != task else { return }
        tracking = (task, live.since)
        touchRecency(task)
        checkpoint()
    }

    public func stop() {
        guard let live = tracking else { return }
        tracking = nil
        try? journal.deleteSession(Self.liveCheckpointID)
        let end = now()
        guard end.timeIntervalSince(live.since) >= 30 else { return }   // taps, not slices
        let s = Session(task: live.task, start: live.since, end: end,
                        certainty: 1.0, comment: nil)
        try? journal.save(s)
        try? journal.escalateOrigin(s.id, to: .manual)
        touchRecency(live.task)
        Task { await pushIfEligible() }
    }

    private func checkpoint() {
        guard let live = tracking else { return }
        try? journal.update(Session(id: Self.liveCheckpointID, task: live.task,
                                    start: live.since, end: now(), certainty: 1.0,
                                    pushedToOP: true))
    }

    /// App relaunch: a checkpoint row means a manual slice was running when
    /// the app died — resume it (manual tracking is deliberate; keep going).
    private func restoreLiveSlice() {
        guard let stale = try? journal.session(id: Self.liveCheckpointID) else { return }
        tracking = (stale.task, stale.start)
    }

    /// Foreground/background hooks call this so a long-running slice's
    /// checkpoint stays fresh without any timer.
    public func appLifecycleTick() {
        checkpoint()
    }

    // MARK: - Task list

    /// Recent-first then ranked — the same ordering the Mac popover uses.
    public func pickList(filter: String = "") -> [WorkTask] {
        let ranked = ranker.recentThenRanked(taskCache, at: now())
        guard !filter.isEmpty else { return ranked }
        return FuzzyMatch.filter(ranked, query: filter)
    }

    public func name(of ref: TaskRef) -> String {
        taskCache.first { $0.ref == ref }?.subject ?? ref.fallbackLabel
    }

    @discardableResult
    public func addLocalTask(name: String) -> TaskRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = settings.localTasks.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) { return .local(existing.id) }
        let def = LocalTaskDef(name: trimmed)
        settings.localTasks.append(def)
        return .local(def.id)
    }

    private func mergeLocalTasks() {
        let locals = settings.localTasks.map {
            WorkTask(ref: .local($0.id), subject: $0.name,
                     project: $0.projectName, status: "Open")
        }
        taskCache = taskCache.filter { $0.ref.isRemote } + locals
    }

    private func touchRecency(_ ref: TaskRef) {
        if let i = taskCache.firstIndex(where: { $0.ref == ref }) {
            taskCache[i].lastConfirmedAt = now()
        }
    }

    // MARK: - Backend (OP works fully on iOS; Xero arrives via the Pro app)

    public func saveAPIKey(_ key: String) {
        do { try APIKeyStore.saveAPIKey(key) } catch {
            lastError = "API key save failed – \(error)"
            return
        }
        rebuildBackend()
        Task { await refreshTasks() }
    }

    private func rebuildBackend() {
        backend = nil
        connectedAs = nil
        let raw = settings.opBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.host != nil,
              let key = try? APIKeyStore.loadAPIKey() else { return }
        backend = OPBackend(baseURL: url, apiKey: key, transport: URLSessionTransport())
    }

    public func refreshTasks() async {
        guard let backend else { return }
        do {
            if connectedAs == nil { connectedAs = try? await backend.fetchMe() }
            let recency = Dictionary(uniqueKeysWithValues:
                taskCache.compactMap { t in t.lastConfirmedAt.map { (t.ref, $0) } })
            var fetched = try await backend.fetchTasks()
            for i in fetched.indices {
                fetched[i].lastConfirmedAt = recency[fetched[i].ref]
            }
            taskCache = fetched + taskCache.filter { !$0.ref.isRemote }
            lastError = nil
        } catch {
            lastError = "\(backend.displayName) fetch failed: \(error)"
        }
    }

    private func pushIfEligible() async {
        guard let backend else { return }
        let engine = SyncEngine(journal: journal, backend: backend,
                                id: OPBackend.stableID, class: .pm)
        engine.excludedSessionIDs = [Self.liveCheckpointID]
        _ = await engine.pushEligible(
            threshold: settings.certaintyAutoPushThreshold,
            defaultActivityID: settings.defaultActivityID,
            activityOverrides: settings.activityOverrides,
            includeComments: false)
    }

    // MARK: - Totals + export

    /// Time Spent hierarchy for the phone pie: project -> task, the live
    /// slice included and sessions clipped to the range so totals never
    /// double-count across days. Mirrors the Mac's spentNodes minus the app
    /// level (iOS senses no apps, so there are no focus spans).
    public func spentNodes(from: Date, to: Date) -> [TimeAggregator.Node] {
        var sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
            .map { s -> Session in
                var c = s
                c.start = max(s.start, from)
                c.end = min(s.end, to)
                return c
            }
        if let live = tracking, live.since < to, now() > from {
            sessions.append(Session(task: live.task, start: max(live.since, from),
                                    end: min(now(), to), certainty: 1.0))
        }
        return TimeAggregator.byProject(sessions: sessions, tasks: taskCache)
    }

    /// Banked slices in start order (checkpoint row excluded) — the timeline
    /// page's data; the live slice comes from `tracking`.
    public func bankedSessions(from: Date, to: Date) -> [Session] {
        ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
            .sorted { $0.start < $1.start }
    }

    public func todaysTotal() -> TimeInterval {
        let start = Calendar.current.startOfDay(for: now())
        let sessions = ((try? journal.sessions(from: start, to: now())) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        let banked = sessions.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let live = tracking.map { now().timeIntervalSince($0.since) } ?? 0
        return banked + live
    }

    public func timesheetCSV(days: Int = 7) -> String {
        let from = now().addingTimeInterval(-Double(days) * 86_400)
        let sessions = ((try? journal.sessions(from: from, to: now())) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        return TimesheetExport.csv(sessions: sessions) { [weak self] ref in
            (self?.name(of: ref) ?? ref.fallbackLabel,
             self?.taskCache.first { $0.ref == ref }?.project)
        }
    }
}

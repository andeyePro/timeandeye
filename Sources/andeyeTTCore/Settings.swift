import Foundation

/// A user-defined non-OpenProject task (leisure, life admin, ...): tracked,
/// timelined and charted like any other task, never pushed to OP.
public struct LocalTaskDef: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isLeisure: Bool
    /// Local "project" this task groups under in Time Spent (parity with OP's
    /// project → task hierarchy). Optional so older saved settings still decode;
    /// nil/empty is treated as "Personal".
    public var project: String?

    public init(id: UUID = UUID(), name: String, isLeisure: Bool = false,
                project: String? = nil) {
        self.id = id
        self.name = name
        self.isLeisure = isLeisure
        self.project = project
    }

    /// The project name to display/group under (never empty).
    public var projectName: String {
        let p = (project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "Personal" : p
    }
}

public extension TaskRef {
    /// Stable string key for settings maps (colours etc.).
    var storageKey: String {
        switch self {
        case .op(let id): return "op:\(id)"
        case .remote(let id): return "remote:\(id)"
        case .local(let uuid): return "local:\(uuid.uuidString)"
        }
    }
}

/// The two time views (one combined entry point opens one of them).
public enum TimeView: String, Codable, Sendable, CaseIterable { case timeline, spent }

/// What the combined Time entry point opens: always the timeline, always the
/// pie, or whichever was viewed last.
public enum TimeViewOpenMode: String, Codable, Sendable, CaseIterable {
    case timeline, lastViewed, spent
}

/// All user-tunable knobs. The OP API key is NOT here – it lives in a 0600 file
/// (see APIKeyStore). Persist via JSONFileStore.
public struct AndeyeSettings: Codable, Equatable, Sendable {
    public var opBaseURL: String
    /// Sessions at/above this certainty auto-push to OP. > 1.0 means never.
    public var certaintyAutoPushThreshold: Double
    public var colourLow: String      // hex; certainty 0 end of the gradient
    public var colourHigh: String     // hex; certainty 1 end
    public var showPercent: Bool
    public var defaultActivityID: Int?
    public var activityOverrides: [TaskRef: Int]
    public var autoComment: Bool
    /// Attach the manual note to the tracked-time entry (the time-entry comment).
    public var commentToTrackedTime: Bool
    /// Also post the manual note to the task's activity feed, where it is far
    /// easier to find than buried on a single time entry.
    public var commentToTask: Bool
    public var trackLeisureLocally: Bool
    public var statusOrder: [String]
    public var primeDwellSeconds: Double
    public var minSegmentSeconds: Double
    public var switchGraceSeconds: Double
    public var sleepGraceSeconds: Double
    /// How long after an idle stop the one-tap "count the gap as <task>" offer
    /// stays available (the gap defaults to a break if untouched).
    public var idleBackfillWindowSeconds: Double
    /// Show the prominent "worked on X while away?" popover button at all.
    /// Off by default — the offer is opt-in, not a surprise prompt.
    public var offerIdleBackfill: Bool
    /// First N characters of the tracked task name shown in the menu bar; 0 = off.
    public var menuTaskChars: Int
    public var systemNotifications: Bool
    /// The popover's default mode when tracking: true = "Change to" (relabel the
    /// running session), false = "Switch to" (start a fresh session). Clicking
    /// the running task title flips to the other mode for that open.
    public var popoverDefaultsToChangeMode: Bool
    /// Which time view the combined entry point opens (timeline / last / pie).
    public var timeViewOpenMode: TimeViewOpenMode
    /// The last time view opened — persisted so "last viewed" survives a restart.
    public var lastViewedTimeView: TimeView
    /// Lock the Mac when "I'm leaving my desk" is activated.
    public var lockOnLeave: Bool
    /// Non-OP tasks (leisure etc.), fully tracked locally.
    public var localTasks: [LocalTaskDef]
    /// User colour overrides per task (TaskRef.storageKey -> hex).
    public var taskColours: [String: String]
    /// The email→task specificity ladder (general → specific); the most specific
    /// matching rule wins. User-reorderable.
    public var emailMatchOrder: [EmailMatchLevel]
    /// The pasted licence key (a signed token, not a secret — safe in the
    /// settings file). nil/invalid = Community tier, fully functional.
    public var licenseKey: String?
    /// Multi-device journal sync (CloudKit). Default OFF: until enabled the
    /// store behaves exactly pre-sync. Flipping on stamps the backlog and
    /// starts the replica cycle (needs the CloudKit-entitled build).
    public var journalSyncEnabled: Bool
    /// Currency symbol shown wherever billable totals render. nil/empty =
    /// the locale's own symbol (CurrencyDefault.symbol()); ONE override
    /// field, no settings sprawl.
    public var currencySymbolOverride: String?

    public init(opBaseURL: String,
                certaintyAutoPushThreshold: Double = 0.8,
                colourLow: String = "#FF3B30",
                colourHigh: String = "#34C759",
                showPercent: Bool = false,
                defaultActivityID: Int? = nil,
                activityOverrides: [TaskRef: Int] = [:],
                autoComment: Bool = false,
                commentToTrackedTime: Bool = true,
                commentToTask: Bool = true,
                trackLeisureLocally: Bool = false,
                statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                primeDwellSeconds: Double = 30,
                minSegmentSeconds: Double = 20,
                switchGraceSeconds: Double = 30,
                sleepGraceSeconds: Double = 60,
                idleBackfillWindowSeconds: Double = 18 * 3600,
                offerIdleBackfill: Bool = false,
                menuTaskChars: Int = 5,
                systemNotifications: Bool = true,
                popoverDefaultsToChangeMode: Bool = true,
                timeViewOpenMode: TimeViewOpenMode = .lastViewed,
                lastViewedTimeView: TimeView = .timeline,
                lockOnLeave: Bool = false,
                localTasks: [LocalTaskDef] = [],
                taskColours: [String: String] = [:],
                emailMatchOrder: [EmailMatchLevel] = EmailMatchLevel.defaultOrder,
                licenseKey: String? = nil,
                journalSyncEnabled: Bool = false,
                currencySymbolOverride: String? = nil) {
        self.opBaseURL = opBaseURL
        self.certaintyAutoPushThreshold = certaintyAutoPushThreshold
        self.colourLow = colourLow
        self.colourHigh = colourHigh
        self.showPercent = showPercent
        self.defaultActivityID = defaultActivityID
        self.activityOverrides = activityOverrides
        self.autoComment = autoComment
        self.commentToTrackedTime = commentToTrackedTime
        self.commentToTask = commentToTask
        self.trackLeisureLocally = trackLeisureLocally
        self.statusOrder = statusOrder
        self.primeDwellSeconds = primeDwellSeconds
        self.minSegmentSeconds = minSegmentSeconds
        self.switchGraceSeconds = switchGraceSeconds
        self.sleepGraceSeconds = sleepGraceSeconds
        self.idleBackfillWindowSeconds = idleBackfillWindowSeconds
        self.offerIdleBackfill = offerIdleBackfill
        self.menuTaskChars = menuTaskChars
        self.systemNotifications = systemNotifications
        self.popoverDefaultsToChangeMode = popoverDefaultsToChangeMode
        self.timeViewOpenMode = timeViewOpenMode
        self.lastViewedTimeView = lastViewedTimeView
        self.lockOnLeave = lockOnLeave
        self.localTasks = localTasks
        self.taskColours = taskColours
        self.emailMatchOrder = emailMatchOrder
        self.licenseKey = licenseKey
        self.journalSyncEnabled = journalSyncEnabled
        self.currencySymbolOverride = currencySymbolOverride
    }

    /// Tolerant decoding: EVERY field falls back to its default for an absent OR
    /// malformed/renamed value, so no single corrupt field can throw and take the
    /// whole settings file (and with it the OP URL) down. This has bitten twice
    /// (a renamed enum rawValue both times) — `try ... ?? default` only catches a
    /// nil, NOT a thrown decode, so each field must swallow its own throw.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AndeyeSettings(opBaseURL: "")
        opBaseURL = c.lenient(.opBaseURL, or: defaults.opBaseURL)
        certaintyAutoPushThreshold = c.lenient(.certaintyAutoPushThreshold, or: defaults.certaintyAutoPushThreshold)
        colourLow = c.lenient(.colourLow, or: defaults.colourLow)
        colourHigh = c.lenient(.colourHigh, or: defaults.colourHigh)
        showPercent = c.lenient(.showPercent, or: defaults.showPercent)
        defaultActivityID = ((try? c.decodeIfPresent(Int.self, forKey: .defaultActivityID)) ?? nil) ?? defaults.defaultActivityID
        activityOverrides = c.lenient(.activityOverrides, or: defaults.activityOverrides)
        autoComment = c.lenient(.autoComment, or: defaults.autoComment)
        commentToTrackedTime = c.lenient(.commentToTrackedTime, or: defaults.commentToTrackedTime)
        commentToTask = c.lenient(.commentToTask, or: defaults.commentToTask)
        trackLeisureLocally = c.lenient(.trackLeisureLocally, or: defaults.trackLeisureLocally)
        statusOrder = c.lenient(.statusOrder, or: defaults.statusOrder)
        primeDwellSeconds = c.lenient(.primeDwellSeconds, or: defaults.primeDwellSeconds)
        minSegmentSeconds = c.lenient(.minSegmentSeconds, or: defaults.minSegmentSeconds)
        switchGraceSeconds = c.lenient(.switchGraceSeconds, or: defaults.switchGraceSeconds)
        sleepGraceSeconds = c.lenient(.sleepGraceSeconds, or: defaults.sleepGraceSeconds)
        idleBackfillWindowSeconds = c.lenient(.idleBackfillWindowSeconds, or: defaults.idleBackfillWindowSeconds)
        offerIdleBackfill = c.lenient(.offerIdleBackfill, or: defaults.offerIdleBackfill)
        menuTaskChars = c.lenient(.menuTaskChars, or: defaults.menuTaskChars)
        systemNotifications = c.lenient(.systemNotifications, or: defaults.systemNotifications)
        popoverDefaultsToChangeMode = c.lenient(.popoverDefaultsToChangeMode, or: defaults.popoverDefaultsToChangeMode)
        timeViewOpenMode = c.lenient(.timeViewOpenMode, or: defaults.timeViewOpenMode)
        lastViewedTimeView = c.lenient(.lastViewedTimeView, or: defaults.lastViewedTimeView)
        lockOnLeave = c.lenient(.lockOnLeave, or: defaults.lockOnLeave)
        localTasks = c.lenient(.localTasks, or: defaults.localTasks)
        taskColours = c.lenient(.taskColours, or: defaults.taskColours)
        // Decode the ladder as raw strings and map known levels, so a renamed /
        // unknown level can never throw (which would wipe the whole file). Only a
        // COMPLETE, valid order is honoured; anything else → the default order.
        let rawOrder = ((try? c.decodeIfPresent([String].self, forKey: .emailMatchOrder)) ?? nil) ?? []
        let mapped = rawOrder.compactMap { EmailMatchLevel(rawValue: $0) }
        emailMatchOrder = Set(mapped) == Set(EmailMatchLevel.allCases) ? mapped : defaults.emailMatchOrder
        licenseKey = ((try? c.decodeIfPresent(String.self, forKey: .licenseKey)) ?? nil) ?? defaults.licenseKey
        journalSyncEnabled = c.lenient(.journalSyncEnabled, or: defaults.journalSyncEnabled)
        currencySymbolOverride = ((try? c.decodeIfPresent(String.self, forKey: .currencySymbolOverride)) ?? nil)
            ?? defaults.currencySymbolOverride
    }
}

public extension AndeyeSettings {
    /// The symbol billable totals render with: the one override field when
    /// set, else the locale default.
    var effectiveCurrencySymbol: String {
        if let symbol = currencySymbolOverride?.trimmingCharacters(in: .whitespaces),
           !symbol.isEmpty {
            return symbol
        }
        return CurrencyDefault.symbol()
    }
}

private extension KeyedDecodingContainer {
    /// Decode `key`, returning `fallback` for an absent OR malformed/renamed value.
    /// Swallows the throw so one corrupt field can't fail the whole container.
    func lenient<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Tiny atomic JSON persistence for any Codable (settings, LearningStore, ...).
public final class JSONFileStore<Value: Codable> {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var backupURL: URL { url.appendingPathExtension("bak") }

    /// Decode the main file; if it is present but UNREADABLE, preserve it as
    /// `.corrupt` (so nothing is silently lost) and fall back to the last-good
    /// `.bak`. A genuinely-absent file returns nil (first run). This stops a
    /// single bad read from leading the caller to default-then-overwrite.
    public func load() throws -> Value? {
        do {
            if let value = try decodeFile(url) { return value }
        } catch {
            let corrupt = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.copyItem(at: url, to: corrupt)
            if let recovered = try? decodeFile(backupURL) { return recovered }
            throw error
        }
        // Main absent — a backup may still hold the last-good copy.
        return try? decodeFile(backupURL) ?? nil
    }

    private func decodeFile(_ u: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: u))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        // Mirror the just-written (known-good) file as the backup, so load() can
        // recover the LATEST value if the main is later corrupted — and so a
        // corrupt main can never become the backup.
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }
}

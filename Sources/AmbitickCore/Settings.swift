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
public struct AmbitickSettings: Codable, Equatable, Sendable {
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
                menuTaskChars: Int = 5,
                systemNotifications: Bool = true,
                popoverDefaultsToChangeMode: Bool = true,
                timeViewOpenMode: TimeViewOpenMode = .lastViewed,
                lastViewedTimeView: TimeView = .timeline,
                lockOnLeave: Bool = false,
                localTasks: [LocalTaskDef] = [],
                taskColours: [String: String] = [:],
                emailMatchOrder: [EmailMatchLevel] = EmailMatchLevel.defaultOrder) {
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
        self.menuTaskChars = menuTaskChars
        self.systemNotifications = systemNotifications
        self.popoverDefaultsToChangeMode = popoverDefaultsToChangeMode
        self.timeViewOpenMode = timeViewOpenMode
        self.lastViewedTimeView = lastViewedTimeView
        self.lockOnLeave = lockOnLeave
        self.localTasks = localTasks
        self.taskColours = taskColours
        self.emailMatchOrder = emailMatchOrder
    }

    /// Tolerant decoding: new fields fall back to their defaults instead of
    /// failing the whole settings file when an older settings.json is loaded.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AmbitickSettings(opBaseURL: "")
        opBaseURL = try c.decodeIfPresent(String.self, forKey: .opBaseURL) ?? defaults.opBaseURL
        certaintyAutoPushThreshold = try c.decodeIfPresent(Double.self, forKey: .certaintyAutoPushThreshold) ?? defaults.certaintyAutoPushThreshold
        colourLow = try c.decodeIfPresent(String.self, forKey: .colourLow) ?? defaults.colourLow
        colourHigh = try c.decodeIfPresent(String.self, forKey: .colourHigh) ?? defaults.colourHigh
        showPercent = try c.decodeIfPresent(Bool.self, forKey: .showPercent) ?? defaults.showPercent
        defaultActivityID = try c.decodeIfPresent(Int.self, forKey: .defaultActivityID) ?? defaults.defaultActivityID
        activityOverrides = try c.decodeIfPresent([TaskRef: Int].self, forKey: .activityOverrides) ?? defaults.activityOverrides
        autoComment = try c.decodeIfPresent(Bool.self, forKey: .autoComment) ?? defaults.autoComment
        commentToTrackedTime = try c.decodeIfPresent(Bool.self, forKey: .commentToTrackedTime) ?? defaults.commentToTrackedTime
        commentToTask = try c.decodeIfPresent(Bool.self, forKey: .commentToTask) ?? defaults.commentToTask
        trackLeisureLocally = try c.decodeIfPresent(Bool.self, forKey: .trackLeisureLocally) ?? defaults.trackLeisureLocally
        statusOrder = try c.decodeIfPresent([String].self, forKey: .statusOrder) ?? defaults.statusOrder
        primeDwellSeconds = try c.decodeIfPresent(Double.self, forKey: .primeDwellSeconds) ?? defaults.primeDwellSeconds
        minSegmentSeconds = try c.decodeIfPresent(Double.self, forKey: .minSegmentSeconds) ?? defaults.minSegmentSeconds
        switchGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .switchGraceSeconds) ?? defaults.switchGraceSeconds
        sleepGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .sleepGraceSeconds) ?? defaults.sleepGraceSeconds
        idleBackfillWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .idleBackfillWindowSeconds) ?? defaults.idleBackfillWindowSeconds
        menuTaskChars = try c.decodeIfPresent(Int.self, forKey: .menuTaskChars) ?? defaults.menuTaskChars
        systemNotifications = try c.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? defaults.systemNotifications
        popoverDefaultsToChangeMode = try c.decodeIfPresent(Bool.self, forKey: .popoverDefaultsToChangeMode) ?? defaults.popoverDefaultsToChangeMode
        // Enum-typed fields decode LENIENTLY: an unknown/renamed rawValue must
        // drop to the default, never throw and take the whole settings file (and
        // with it the OP URL) down. `try` only short-circuits a thrown decode;
        // `??` alone catches nil but NOT a throw.
        timeViewOpenMode = ((try? c.decodeIfPresent(TimeViewOpenMode.self, forKey: .timeViewOpenMode)) ?? nil) ?? defaults.timeViewOpenMode
        lastViewedTimeView = ((try? c.decodeIfPresent(TimeView.self, forKey: .lastViewedTimeView)) ?? nil) ?? defaults.lastViewedTimeView
        lockOnLeave = try c.decodeIfPresent(Bool.self, forKey: .lockOnLeave) ?? defaults.lockOnLeave
        localTasks = try c.decodeIfPresent([LocalTaskDef].self, forKey: .localTasks) ?? defaults.localTasks
        taskColours = try c.decodeIfPresent([String: String].self, forKey: .taskColours) ?? defaults.taskColours
        // Decode the ladder as raw strings and map known levels, so a renamed /
        // unknown level can never throw (which would wipe the whole file). Only a
        // COMPLETE, valid order is honoured; anything else → the default order.
        let rawOrder = ((try? c.decodeIfPresent([String].self, forKey: .emailMatchOrder)) ?? nil) ?? []
        let mapped = rawOrder.compactMap { EmailMatchLevel(rawValue: $0) }
        emailMatchOrder = Set(mapped) == Set(EmailMatchLevel.allCases) ? mapped : defaults.emailMatchOrder
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

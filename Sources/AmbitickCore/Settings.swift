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

/// All user-tunable knobs. The OP API key is NOT here – it lives in the
/// macOS Keychain. Persist via JSONFileStore.
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
    /// Saved per-task window layouts (keyed by TaskRef.storageKey) + the most
    /// recent capture, for "Open workspace" (launch & arrange the task's apps).
    public var taskLayouts: [String: [WindowFrame]]
    public var lastLayout: [WindowFrame]
    public var systemNotifications: Bool
    /// Lock the Mac when "I'm leaving my desk" is activated.
    public var lockOnLeave: Bool
    /// Non-OP tasks (leisure etc.), fully tracked locally.
    public var localTasks: [LocalTaskDef]
    /// User colour overrides per task (TaskRef.storageKey -> hex).
    public var taskColours: [String: String]

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
                taskLayouts: [String: [WindowFrame]] = [:],
                lastLayout: [WindowFrame] = [],
                systemNotifications: Bool = true,
                lockOnLeave: Bool = false,
                localTasks: [LocalTaskDef] = [],
                taskColours: [String: String] = [:]) {
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
        self.taskLayouts = taskLayouts
        self.lastLayout = lastLayout
        self.systemNotifications = systemNotifications
        self.lockOnLeave = lockOnLeave
        self.localTasks = localTasks
        self.taskColours = taskColours
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
        taskLayouts = try c.decodeIfPresent([String: [WindowFrame]].self, forKey: .taskLayouts) ?? defaults.taskLayouts
        lastLayout = try c.decodeIfPresent([WindowFrame].self, forKey: .lastLayout) ?? defaults.lastLayout
        systemNotifications = try c.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? defaults.systemNotifications
        lockOnLeave = try c.decodeIfPresent(Bool.self, forKey: .lockOnLeave) ?? defaults.lockOnLeave
        localTasks = try c.decodeIfPresent([LocalTaskDef].self, forKey: .localTasks) ?? defaults.localTasks
        taskColours = try c.decodeIfPresent([String: String].self, forKey: .taskColours) ?? defaults.taskColours
    }
}

/// Tiny atomic JSON persistence for any Codable (settings, LearningStore, ...).
public final class JSONFileStore<Value: Codable> {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

import Foundation

public enum Ambitick {
    public static let version = "0.1.0"
}

/// Identity of a task. `.op` = OpenProject work package; `.local` = Ambitick-only
/// (leisure tracking etc.), never pushed to OP.
public enum TaskRef: Hashable, Codable, Sendable {
    case op(Int)
    case local(UUID)
}

/// What a stretch of time can be attributed to.
public enum Target: Hashable, Codable, Sendable {
    case task(TaskRef)
    case doNotTrack
}

public struct WorkTask: Equatable, Codable, Sendable {
    public var ref: TaskRef
    public var subject: String
    public var project: String?
    public var status: String
    public var lastConfirmedAt: Date?
    public var assignee: String?

    public var isLocalOnly: Bool {
        if case .local = ref { return true }
        return false
    }

    public init(ref: TaskRef, subject: String, project: String? = nil,
                status: String, lastConfirmedAt: Date? = nil, assignee: String? = nil) {
        self.ref = ref
        self.subject = subject
        self.project = project
        self.status = status
        self.lastConfirmedAt = lastConfirmedAt
        self.assignee = assignee
    }
}

/// One observation from the sensors: what is focused right now.
public struct ActivitySignal: Equatable, Codable, Sendable {
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var timestamp: Date

    public init(app: String, windowTitle: String? = nil, tabURL: String? = nil,
                timestamp: Date) {
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.timestamp = timestamp
    }
}

/// Everything the platform sensor layer can tell Core. Sensors emit these;
/// Core tests emit them from scripts.
public enum SensorEvent: Equatable, Sendable {
    case focus(ActivitySignal)
    case input(Date)                     // keyboard/mouse seen at this time
    case willSleep(Date)
    case didWake(Date)
    case microphone(active: Bool, at: Date)
}

/// The stable identity of a window/tab for priming and learning:
/// URL host+path when there is a URL, else the window title.
public struct Surface: Hashable, Codable, Sendable {
    public var app: String
    public var detail: String

    public init(app: String, detail: String) {
        self.app = app
        self.detail = detail
    }

    public init(signal: ActivitySignal) {
        self.app = signal.app
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            var path = url.path
            while path.hasSuffix("/") { path = String(path.dropLast()) }   // platform-stable
            self.detail = host + path
        } else {
            self.detail = signal.windowTitle ?? ""
        }
    }
}

/// A contiguous stretch of focus on one surface, attributed to one target.
public struct FocusSpan: Equatable, Sendable {
    public var target: Target
    public var certainty: Double
    public var signal: ActivitySignal
    public var start: Date
    public var end: Date

    public init(target: Target, certainty: Double, signal: ActivitySignal,
                start: Date, end: Date) {
        self.target = target
        self.certainty = certainty
        self.signal = signal
        self.start = start
        self.end = end
    }
}

/// A closed, journalled stretch of tracked time on one task.
public struct Session: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var task: TaskRef
    public var start: Date
    public var end: Date
    public var certainty: Double
    public var pushedToOP: Bool
    public var comment: String?

    public init(id: UUID = UUID(), task: TaskRef, start: Date, end: Date,
                certainty: Double, pushedToOP: Bool = false, comment: String? = nil) {
        self.id = id
        self.task = task
        self.start = start
        self.end = end
        self.certainty = certainty
        self.pushedToOP = pushedToOP
        self.comment = comment
    }
}

/// One coalesced row in the review queue (low-certainty time awaiting assignment).
public struct ReviewSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var start: Date
    public var end: Date
    public var assigned: Target?

    public init(id: UUID = UUID(), app: String, windowTitle: String? = nil,
                tabURL: String? = nil, start: Date, end: Date, assigned: Target? = nil) {
        self.id = id
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.start = start
        self.end = end
        self.assigned = assigned
    }
}

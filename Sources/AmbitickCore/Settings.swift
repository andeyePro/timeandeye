import Foundation

/// All user-tunable knobs. The OP API key is NOT here – it lives in the
/// macOS Keychain. Persist via JSONFileStore.
public struct AmbitickSettings: Codable, Equatable, Sendable {
    public var opBaseURL: String
    public var recentCount: Int
    public var likelyCount: Int
    /// Sessions at/above this certainty auto-push to OP. > 1.0 means never.
    public var certaintyAutoPushThreshold: Double
    public var colourLow: String      // hex; certainty 0 end of the gradient
    public var colourHigh: String     // hex; certainty 1 end
    public var showPercent: Bool
    public var defaultActivityID: Int?
    public var activityOverrides: [TaskRef: Int]
    public var autoComment: Bool
    public var trackLeisureLocally: Bool
    public var statusOrder: [String]
    public var primeDwellSeconds: Double
    public var minSegmentSeconds: Double

    public init(opBaseURL: String,
                recentCount: Int = 5,
                likelyCount: Int = 5,
                certaintyAutoPushThreshold: Double = 0.8,
                colourLow: String = "#FF3B30",
                colourHigh: String = "#34C759",
                showPercent: Bool = false,
                defaultActivityID: Int? = nil,
                activityOverrides: [TaskRef: Int] = [:],
                autoComment: Bool = true,
                trackLeisureLocally: Bool = false,
                statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                primeDwellSeconds: Double = 30,
                minSegmentSeconds: Double = 20) {
        self.opBaseURL = opBaseURL
        self.recentCount = recentCount
        self.likelyCount = likelyCount
        self.certaintyAutoPushThreshold = certaintyAutoPushThreshold
        self.colourLow = colourLow
        self.colourHigh = colourHigh
        self.showPercent = showPercent
        self.defaultActivityID = defaultActivityID
        self.activityOverrides = activityOverrides
        self.autoComment = autoComment
        self.trackLeisureLocally = trackLeisureLocally
        self.statusOrder = statusOrder
        self.primeDwellSeconds = primeDwellSeconds
        self.minSegmentSeconds = minSegmentSeconds
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

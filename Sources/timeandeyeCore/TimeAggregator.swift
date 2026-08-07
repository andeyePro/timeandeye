import Foundation

/// Builds the Time Spent hierarchy: project -> task -> app, from journalled
/// sessions (+ spans for the app level). Pure and checkable.
public enum TimeAggregator {
    public struct Node: Equatable, Sendable {
        public var label: String
        public var seconds: TimeInterval
        public var ref: TaskRef?
        public var children: [Node]

        public init(label: String, seconds: TimeInterval, ref: TaskRef? = nil,
                    children: [Node] = []) {
            self.label = label
            self.seconds = seconds
            self.ref = ref
            self.children = children
        }
    }

    /// localProjectName groups all `.local` tasks (leisure etc.).
    public static func byProject(sessions: [Session], tasks: [WorkTask],
                                 spans: [FocusSpan] = [],
                                 localProjectName: String = "Personal") -> [Node] {
        var perTask: [TaskRef: TimeInterval] = [:]
        var taskWindows: [TaskRef: [(Date, Date)]] = [:]
        for session in sessions {
            let d = session.end.timeIntervalSince(session.start)
            guard d > 0 else { continue }
            perTask[session.task, default: 0] += d
            taskWindows[session.task, default: []].append((session.start, session.end))
        }

        var projects: [String: [Node]] = [:]
        // Deterministic iteration (perTask is a Dictionary — Swift randomises
        // its order per process): build the node arrays stably so the
        // non-associative float sum below and the tie-order don't flip launch
        // to launch (the same class as the LearningStore softmax fix).
        for (ref, seconds) in perTask.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            let task = tasks.first { $0.ref == ref }
            let project = task.flatMap(\.project)
                ?? (task?.isLocalOnly == true || isLocal(ref) ? localProjectName : "Other")
            let label = task?.subject ?? fallbackLabel(ref)
            let apps = appBreakdown(for: ref, windows: taskWindows[ref] ?? [], spans: spans)
            projects[project, default: []].append(
                Node(label: label, seconds: seconds, ref: ref, children: apps))
        }

        return projects.map { name, taskNodes in
            Node(label: name,
                 seconds: taskNodes.reduce(0) { $0 + $1.seconds },
                 children: taskNodes.sorted {
                     $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label })
        }
        .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }

    private static func isLocal(_ ref: TaskRef) -> Bool {
        if case .local = ref { return true }
        return false
    }

    private static func fallbackLabel(_ ref: TaskRef) -> String {
        ref.fallbackLabel
    }

    /// App-level breakdown: spans attributed to this task, clipped to its
    /// session windows, grouped by application name.
    private static func appBreakdown(for ref: TaskRef, windows: [(Date, Date)],
                                     spans: [FocusSpan]) -> [Node] {
        var perApp: [String: TimeInterval] = [:]
        // Away-observed spans always carry target .doNotTrack, never
        // .task(_), so this filter already excludes them from the app
        // breakdown — no separate observedWhileAway check needed here.
        for span in spans where span.target == .task(ref) {
            for (start, end) in windows {
                let overlap = min(span.end, end).timeIntervalSince(max(span.start, start))
                if overlap > 0 {
                    perApp[span.signal.app, default: 0] += overlap
                }
            }
        }
        return perApp.map { Node(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }
}

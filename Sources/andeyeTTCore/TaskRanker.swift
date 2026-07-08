import Foundation

public struct RankingConfig: Codable, Equatable, Sendable {
    public var statusOrder: [String]
    public var recencyHalfLifeDays: Double
    /// The local user's display name: tasks assigned to OTHERS sink to the
    /// bottom of every list until the user actually tracks time on them.
    public var currentUser: String?

    public init(statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                recencyHalfLifeDays: Double = 7,
                currentUser: String? = nil) {
        self.statusOrder = statusOrder
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.currentUser = currentUser
    }
}

public struct TaskRanker: Sendable {
    public var config: RankingConfig

    public init(config: RankingConfig = RankingConfig()) {
        self.config = config
    }

    /// Status prior + exponentially-decayed recency + time-of-day affinity.
    /// Recency carries double weight so an actively-tracked Closed task
    /// (e.g. Timesheets) outranks dormant Open tasks.
    public func score(_ task: WorkTask, at now: Date, learning: LearningStore? = nil,
                      calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        var statusScore = 0.0
        if let idx = config.statusOrder.firstIndex(of: task.status) {
            statusScore = Double(config.statusOrder.count - idx) / Double(config.statusOrder.count)
        }
        var recencyScore = 0.0
        if let last = task.lastConfirmedAt {
            let days = max(now.timeIntervalSince(last), 0) / 86_400
            recencyScore = pow(0.5, days / config.recencyHalfLifeDays)
        }
        var todScore = 0.0
        if let learning {
            todScore = learning.hourAffinity(for: .task(task.ref),
                                             hour: calendar.component(.hour, from: now))
        }
        var score = statusScore + 2 * recencyScore + todScore
        if let assignee = task.assignee, let me = config.currentUser,
           assignee != me, task.lastConfirmedAt == nil {
            score -= 10   // someone else's task: bottom of the list until tracked
        }
        return score
    }

    public func ranked(_ tasks: [WorkTask], at now: Date,
                       learning: LearningStore? = nil) -> [WorkTask] {
        tasks.sorted { score($0, at: now, learning: learning) > score($1, at: now, learning: learning) }
    }

    /// The "pick a task" ordering: every recently-confirmed task first (most
    /// recent first), then everything else in ranked order. No duplicates, no
    /// caps — the popover shows the whole scrollable list, so a fixed
    /// recent/likely count is no longer meaningful; recency-first is the only
    /// guarantee worth keeping (your just-used task sits at the top).
    public func recentThenRanked(_ tasks: [WorkTask], at now: Date,
                                 learning: LearningStore? = nil) -> [WorkTask] {
        // The recent-first block has a HORIZON (reviewer B16): after journal
        // back-fill, every task ever tracked carried a lastConfirmedAt, so
        // ancient one-offs sat above never-tracked "Now" tasks forever. Two
        // half-lives ≈ "recent enough to be your working set"; older tasks
        // still rank normally below (their recency feeds the ranked score).
        let horizon = now.addingTimeInterval(-2 * config.recencyHalfLifeDays * 86_400)
        let recent = tasks
            .compactMap { t in t.lastConfirmedAt.map { (t, $0) } }
            .filter { $0.1 > horizon }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let taken = Set(recent.map(\.ref))
        let rest = ranked(tasks.filter { !taken.contains($0.ref) }, at: now, learning: learning)
        return recent + rest
    }
}

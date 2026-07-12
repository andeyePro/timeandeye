import Foundation

package struct RankingConfig: Codable, Equatable, Sendable {
    package var statusOrder: [String]
    package var recencyHalfLifeDays: Double
    /// The local user's display name: tasks assigned to OTHERS sink to the
    /// bottom of every list until the user actually tracks time on them.
    package var currentUser: String?

    package init(statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                recencyHalfLifeDays: Double = 7,
                currentUser: String? = nil) {
        self.statusOrder = statusOrder
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.currentUser = currentUser
    }
}

package struct TaskRanker: Sendable {
    package var config: RankingConfig

    package init(config: RankingConfig = RankingConfig()) {
        self.config = config
    }

    /// Status prior + exponentially-decayed recency + time-of-day affinity +
    /// a live calendar match. Recency carries double weight so an
    /// actively-tracked Closed task (e.g. Timesheets) outranks dormant Open
    /// tasks. `calendarMatch` is the current live calendar match (if any) –
    /// +0.3 for the matched task (+0.15 if tentative), no change for every
    /// other task and for the no-match case (calendar signal spec §5). The
    /// 0.3 ceiling keeps the term below recency's 2× weight – a live meeting
    /// nudges the ranking, it never dominates demonstrably-recent work.
    package func score(_ task: WorkTask, at now: Date, learning: LearningStore? = nil,
                      calendar: Calendar = Calendar(identifier: .gregorian),
                      calendarMatch: (task: TaskRef, tentative: Bool)? = nil) -> Double {
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
        var calendarScore = 0.0
        if let calendarMatch, calendarMatch.task == task.ref {
            calendarScore = calendarMatch.tentative ? 0.5 : 1.0   // half weight for tentative
        }
        var score = statusScore + 2 * recencyScore + todScore + 0.3 * calendarScore
        if let assignee = task.assignee, let me = config.currentUser,
           assignee != me, task.lastConfirmedAt == nil {
            score -= 10   // someone else's task: bottom of the list until tracked
        }
        return score
    }

    package func ranked(_ tasks: [WorkTask], at now: Date, learning: LearningStore? = nil,
                       calendarMatch: (task: TaskRef, tentative: Bool)? = nil) -> [WorkTask] {
        tasks.sorted {
            score($0, at: now, learning: learning, calendarMatch: calendarMatch)
                > score($1, at: now, learning: learning, calendarMatch: calendarMatch)
        }
    }

    /// The "pick a task" ordering: every recently-confirmed task first (most
    /// recent first), then everything else in ranked order. No duplicates, no
    /// caps — the popover shows the whole scrollable list, so a fixed
    /// recent/likely count is no longer meaningful; recency-first is the only
    /// guarantee worth keeping (your just-used task sits at the top).
    /// `calendarMatch` flows through to the ranked tail exactly as it does in
    /// `score()` – it's what makes a live meeting surface its task without a
    /// separate proposal mechanism (calendar signal spec §5).
    package func recentThenRanked(_ tasks: [WorkTask], at now: Date, learning: LearningStore? = nil,
                                 calendarMatch: (task: TaskRef, tentative: Bool)? = nil) -> [WorkTask] {
        // The built-in Unknown sentinel is review-only — never offered as a
        // pick, however it got into the incoming list. Defense-in-depth: the
        // real seeding boundary is AppController never adding it to
        // taskCache, but this keeps the pick list honest even if a caller
        // (or a future one) feeds it in anyway.
        let tasks = tasks.filter { $0.ref != WorkTask.unknown.ref }
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
        let rest = ranked(tasks.filter { !taken.contains($0.ref) }, at: now, learning: learning,
                          calendarMatch: calendarMatch)
        return recent + rest
    }
}

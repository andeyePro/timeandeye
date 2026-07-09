import Foundation

/// Forgiving task search: substring beats subsequence beats nothing, so
/// "tim" finds Timesheets and "aeml" still finds "andeye email triage".
public enum FuzzyMatch {
    public static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                        locale: nil).makeIterator()
        outer: for ch in needle.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                        locale: nil) {
            while let h = iterator.next() {
                if h == ch { continue outer }
            }
            return false
        }
        return true
    }

    public static func score(_ query: String, in text: String) -> Int {
        // Diacritic folding (reviewer B15): "cafe" finds "Café accounts".
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let t = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if q.isEmpty { return 1 }
        if t.hasPrefix(q) { return 4 }
        if t.contains(" " + q) { return 3 }
        if t.contains(q) { return 2 }
        if isSubsequence(q, of: t) { return 1 }
        return 0
    }

    /// Filter + rank tasks by subject and project, and — when `learnedValues` is
    /// supplied — by the words the learner has associated with each task
    /// (confirmed window-title tokens / hosts / apps). A task ranks by the best of
    /// its subject, project, and learned-value scores, so a query that hits a
    /// learned token surfaces the task even with zero subject overlap ("voting"
    /// finds the "Q3 governance" task you always do in a voting window).
    ///
    /// Learned matches are gated at substring-or-better (score >= 2): a mere
    /// subsequence hit on a learned token is too weak to admit a task whose
    /// visible text doesn't match at all. `learnedValues` defaults to none, so
    /// existing callers keep pure subject/project behaviour.
    public static func filter(_ tasks: [WorkTask], query: String,
                              learnedValues: (TaskRef) -> [String] = { _ in [] }) -> [WorkTask] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return tasks }
        return tasks
            .map { task -> (WorkTask, Int) in
                let textScore = max(score(query, in: task.subject),
                                    score(query, in: task.project ?? ""))
                let learnedScore = learnedValues(task.ref)
                    .map { score(query, in: $0) }
                    .filter { $0 >= 2 }
                    .max() ?? 0
                return (task, max(textScore, learnedScore))
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

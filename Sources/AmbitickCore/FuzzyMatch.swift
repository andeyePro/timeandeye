import Foundation

/// Forgiving task search: substring beats subsequence beats nothing, so
/// "tim" finds Timesheets and "aeml" still finds "andeye email triage".
public enum FuzzyMatch {
    public static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.lowercased().makeIterator()
        outer: for ch in needle.lowercased() {
            while let h = iterator.next() {
                if h == ch { continue outer }
            }
            return false
        }
        return true
    }

    public static func score(_ query: String, in text: String) -> Int {
        let q = query.lowercased()
        let t = text.lowercased()
        if q.isEmpty { return 1 }
        if t.hasPrefix(q) { return 4 }
        if t.contains(" " + q) { return 3 }
        if t.contains(q) { return 2 }
        if isSubsequence(q, of: t) { return 1 }
        return 0
    }

    /// Filter + rank tasks by subject and project.
    public static func filter(_ tasks: [WorkTask], query: String) -> [WorkTask] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return tasks }
        return tasks
            .map { task -> (WorkTask, Int) in
                let s = max(score(query, in: task.subject),
                            score(query, in: task.project ?? ""))
                return (task, s)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

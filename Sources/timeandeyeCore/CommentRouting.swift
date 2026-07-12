import Foundation

/// Where a manual note on tracked time should land, given the two user toggles.
/// Pure so the routing is unit-checkable:
///   - 'comment to tracked time' → the note becomes the time-entry comment
///     (pushed to OP), with the auto window-list comment as the no-note fallback.
///   - 'comment to task' → the note is also posted to the task's activity feed,
///     where it is far easier to find than buried on one time entry.
/// Either, both, or neither. Neither hides the note input entirely.
package enum CommentRouting {
    /// The comment to store on the time entry (and push to OP). The auto
    /// window-list text is used only when there is no manual note and
    /// auto-comment is enabled.
    package static func timeEntryComment(note: String, autoCommentText: String?,
                                        autoCommentEnabled: Bool,
                                        toTrackedTime: Bool) -> String? {
        guard toTrackedTime else { return nil }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
        return autoCommentEnabled ? autoCommentText : nil
    }

    /// The note to post to the task's activity feed, or nil when not commenting
    /// to the task. Only manual notes go to the task — never the auto list.
    package static func taskComment(note: String, toTask: Bool) -> String? {
        guard toTask else { return nil }
        return note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
    }

    /// Whether the note input should be shown at all: hidden only when both
    /// toggles are off (nowhere for a note to go).
    package static func noteInputVisible(toTrackedTime: Bool, toTask: Bool) -> Bool {
        toTrackedTime || toTask
    }

    /// Separator between distinct comments accumulated onto one slice. Matches
    /// the auto window-list joiner ("Xcode; Safari") so a mixed slice reads
    /// uniformly.
    package static let commentSeparator = "; "

    /// Accumulate a freshly-entered comment onto the running comment for the
    /// CURRENT slice. One slice can carry several comments: distinct ones are
    /// joined with `commentSeparator`; a new comment IDENTICAL to the
    /// immediately-preceding accumulated one is ignored (no duplicate). Blank
    /// input is ignored (returns `existing` unchanged). Pure, so the enter-to-
    /// commit accumulation is unit-checkable — the SwiftUI colour flash is not.
    package static func accumulateComment(existing: String, adding: String) -> String {
        let trimmed = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return trimmed }
        // Ignore an exact repeat of the immediately-preceding comment only —
        // an earlier duplicate further back is still allowed to recur.
        if base.components(separatedBy: commentSeparator).last == trimmed { return base }
        return base + commentSeparator + trimmed
    }
}

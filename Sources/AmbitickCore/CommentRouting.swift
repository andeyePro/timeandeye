import Foundation

/// Where a manual note on tracked time should land, given the two user toggles.
/// Pure so the routing is unit-checkable:
///   - 'comment to tracked time' → the note becomes the time-entry comment
///     (pushed to OP), with the auto window-list comment as the no-note fallback.
///   - 'comment to task' → the note is also posted to the task's activity feed,
///     where it is far easier to find than buried on one time entry.
/// Either, both, or neither. Neither hides the note input entirely.
public enum CommentRouting {
    /// The comment to store on the time entry (and push to OP). The auto
    /// window-list text is used only when there is no manual note and
    /// auto-comment is enabled.
    public static func timeEntryComment(note: String, autoCommentText: String?,
                                        autoCommentEnabled: Bool,
                                        toTrackedTime: Bool) -> String? {
        guard toTrackedTime else { return nil }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
        return autoCommentEnabled ? autoCommentText : nil
    }

    /// The note to post to the task's activity feed, or nil when not commenting
    /// to the task. Only manual notes go to the task — never the auto list.
    public static func taskComment(note: String, toTask: Bool) -> String? {
        guard toTask else { return nil }
        return note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
    }

    /// Whether the note input should be shown at all: hidden only when both
    /// toggles are off (nowhere for a note to go).
    public static func noteInputVisible(toTrackedTime: Bool, toTask: Bool) -> Bool {
        toTrackedTime || toTask
    }
}

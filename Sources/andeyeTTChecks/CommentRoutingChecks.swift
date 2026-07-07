import andeyeTTCore

func commentRoutingChecks(_ c: Checks) {
    c.check("time-entry comment: manual note wins when commenting to tracked time") {
        let r = CommentRouting.timeEntryComment(
            note: "fixing the parser", autoCommentText: "Xcode; Safari",
            autoCommentEnabled: true, toTrackedTime: true)
        try expectEq(r, "fixing the parser")
    }

    c.check("time-entry comment: empty note falls back to auto list only when enabled") {
        let on = CommentRouting.timeEntryComment(
            note: "  ", autoCommentText: "Xcode; Safari",
            autoCommentEnabled: true, toTrackedTime: true)
        try expectEq(on, "Xcode; Safari")
        let off = CommentRouting.timeEntryComment(
            note: "", autoCommentText: "Xcode; Safari",
            autoCommentEnabled: false, toTrackedTime: true)
        try expect(off == nil, "auto-comment off drops the window list")
    }

    c.check("time-entry comment: nil when not commenting to tracked time") {
        let r = CommentRouting.timeEntryComment(
            note: "fixing the parser", autoCommentText: "Xcode",
            autoCommentEnabled: true, toTrackedTime: false)
        try expect(r == nil, "toggle off → nothing on the time entry")
    }

    c.check("task comment: only a real manual note, only when commenting to task") {
        try expectEq(CommentRouting.taskComment(note: "resume code abc123", toTask: true),
                     "resume code abc123")
        try expect(CommentRouting.taskComment(note: "   ", toTask: true) == nil,
                   "whitespace-only note is not posted")
        try expect(CommentRouting.taskComment(note: "anything", toTask: false) == nil,
                   "toggle off → nothing on the task")
    }

    c.check("note input hidden only when both toggles are off") {
        try expect(CommentRouting.noteInputVisible(toTrackedTime: false, toTask: false) == false)
        try expect(CommentRouting.noteInputVisible(toTrackedTime: true, toTask: false))
        try expect(CommentRouting.noteInputVisible(toTrackedTime: false, toTask: true))
        try expect(CommentRouting.noteInputVisible(toTrackedTime: true, toTask: true))
    }

    c.check("accumulate: first comment onto an empty slice is the comment itself") {
        try expectEq(CommentRouting.accumulateComment(existing: "", adding: "fixing the parser"),
                     "fixing the parser")
        try expectEq(CommentRouting.accumulateComment(existing: "  ", adding: "  reviewing  "),
                     "reviewing", "both sides trimmed")
    }

    c.check("accumulate: distinct comments concatenate in order, none lost") {
        var acc = CommentRouting.accumulateComment(existing: "", adding: "first")
        acc = CommentRouting.accumulateComment(existing: acc, adding: "second")
        acc = CommentRouting.accumulateComment(existing: acc, adding: "third")
        try expectEq(acc, "first; second; third")
    }

    c.check("accumulate: an immediate exact repeat is ignored (no duplicate)") {
        var acc = CommentRouting.accumulateComment(existing: "first", adding: "first")
        try expectEq(acc, "first", "same-as-last is dropped")
        // Trailing whitespace still counts as the same comment.
        acc = CommentRouting.accumulateComment(existing: "first; second", adding: "  second ")
        try expectEq(acc, "first; second", "immediately-preceding duplicate dropped")
    }

    c.check("accumulate: a repeat that isn't the immediate predecessor is kept") {
        // "first" recurring after "second" is a real re-entry, not a stutter.
        let acc = CommentRouting.accumulateComment(existing: "first; second", adding: "first")
        try expectEq(acc, "first; second; first")
    }

    c.check("accumulate: blank input never changes the accumulated text") {
        try expectEq(CommentRouting.accumulateComment(existing: "first; second", adding: "   "),
                     "first; second")
        try expectEq(CommentRouting.accumulateComment(existing: "first", adding: ""),
                     "first")
    }
}

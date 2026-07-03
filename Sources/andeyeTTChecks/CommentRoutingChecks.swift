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
}

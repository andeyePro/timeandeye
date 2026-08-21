import timeandeyeCore

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

    // Undo of a comment whose slice already FLUSHED (2026-07-09 audit's
    // remaining non-undoable): the note must come OFF the journal row's
    // accumulated comment, exactly once, wherever it sits in the join.
    c.check("removingComment: strips one occurrence, wherever it sits") {
        try expectEq(CommentRouting.removingComment("second", from: "first; second; third"),
                     "first; third")
        try expectEq(CommentRouting.removingComment("first", from: "first; second"),
                     "second")
        try expectEq(CommentRouting.removingComment("second", from: "first; second"),
                     "first")
    }

    c.check("removingComment: the sole comment removed leaves nil, not empty") {
        try expectNil(CommentRouting.removingComment("only", from: "only"))
    }

    c.check("removingComment: a note containing the separator is removed whole") {
        // A single committed note can itself contain "; " — it must be
        // matched as a component RUN, never as a content regex, and only
        // the exact run goes.
        try expectEq(CommentRouting.removingComment("a; b", from: "x; a; b; y"),
                     "x; y")
    }

    c.check("removingComment: absent note / nil comment leave things untouched") {
        try expectEq(CommentRouting.removingComment("gone", from: "first; second"),
                     "first; second")
        try expectNil(CommentRouting.removingComment("anything", from: nil))
        // Only an exact component matches — a substring of a longer comment
        // must never tear that comment apart.
        try expectEq(CommentRouting.removingComment("fir", from: "first; second"),
                     "first; second")
    }
}

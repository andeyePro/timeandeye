import Foundation
import timeandeyeCore

/// A one-shot awaitable gate: lets a check park a group body mid-flight and
/// resume it deterministically. Actor-isolated so the wait/resume handshake is
/// race-free on the cooperative pool.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func release() {
        if let w = waiter { waiter = nil; w.resume() } else { released = true }
    }
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

func undoStackChecks(_ c: Checks) async {
    await c.check("register/pop is LIFO and count tracks it") {
        let u = UndoStack()
        var log: [String] = []
        u.register("first") { log.append("first") }
        u.register("second") { log.append("second") }
        try expectEq(u.count, 2)
        let top = try unwrap(u.pop(), "something to pop")
        try expectEq(top.label, "second", "most recent first")
        await top.inverse()
        try expectEq(log, ["second"])
        try expectEq(u.count, 1)
    }

    c.check("pop on an empty stack returns nil") {
        let u = UndoStack()
        try expect(u.pop() == nil)
    }

    await c.check("a group bundles many registrations into ONE entry, inverses run reversed") {
        let u = UndoStack()
        var log: [String] = []
        await u.group("drag") {
            u.register("a") { log.append("a") }
            u.register("b") { log.append("b") }
            u.register("c") { log.append("c") }
        }
        try expectEq(u.count, 1, "three mutations, one ⌘Z step")
        let entry = try unwrap(u.pop(), "the group entry")
        try expectEq(entry.label, "drag")
        await entry.inverse()
        try expectEq(log, ["c", "b", "a"], "inverses replay newest-first")
    }

    await c.check("nested groups fold into the outermost") {
        let u = UndoStack()
        var log: [String] = []
        await u.group("outer") {
            u.register("x") { log.append("x") }
            await u.group("inner") {
                u.register("y") { log.append("y") }
            }
        }
        try expectEq(u.count, 1, "the inner group does not push its own entry")
        let entry = try unwrap(u.pop(), "entry")
        try expectEq(entry.label, "outer")
        await entry.inverse()
        try expectEq(log, ["y", "x"])
    }

    await c.check("an empty group pushes nothing") {
        let u = UndoStack()
        await u.group("no-op") {}
        try expectEq(u.count, 0)
    }

    await c.check("sync group: the AI batch registers N assignments as ONE ⌘Z step") {
        // ingestAIResponse's shape: parse → N assignReview calls, each of
        // which registers its own inverse. The paste is ONE user gesture, so
        // undoing it must be ONE ⌘Z — and the caller is a synchronous button
        // handler (it returns a status string to show), so it cannot await
        // the async `group` above; `groupSync` exists for exactly this.
        let u = UndoStack()
        var journal = [1: "pending", 2: "pending", 3: "pending"]
        u.groupSync("AI assign 3 review rows") {
            for id in [1, 2, 3] {
                u.register("assign row \(id)") { journal[id] = "pending" }
                journal[id] = "assigned"
            }
        }
        try expectEq(journal.values.filter { $0 == "assigned" }.count, 3)
        try expectEq(u.count, 1, "three assignments, one ⌘Z step")
        let entry = try unwrap(u.pop())
        try expectEq(entry.label, "AI assign 3 review rows")
        await entry.inverse()
        try expectEq(journal, [1: "pending", 2: "pending", 3: "pending"],
                     "one undo unwinds the whole AI batch")
    }

    c.check("an empty sync group pushes nothing (an AI reply with zero assignments)") {
        let u = UndoStack()
        u.groupSync("no-op") {}
        try expectEq(u.count, 0)
    }

    await c.check("a sync group nested in an async group folds into the outermost") {
        // Same nesting contract as async-in-async: an inner group must never
        // split one outer gesture into two ⌘Z steps, whichever flavour it is.
        let u = UndoStack()
        var log: [String] = []
        await u.group("outer") {
            u.register("x") { log.append("x") }
            u.groupSync("inner") { u.register("y") { log.append("y") } }
        }
        try expectEq(u.count, 1, "the inner sync group does not push its own entry")
        let entry = try unwrap(u.pop())
        try expectEq(entry.label, "outer")
        await entry.inverse()
        try expectEq(log, ["y", "x"])
    }

    c.check("the stack is uncapped — 'infinitely undoable' means no silent depth limit") {
        // Martin's directive: "every action can be infinitely undone". A cap
        // would silently drop the OLDEST edits; this pins the no-cap contract
        // (session-bounded is the only limit, and that's documented).
        let u = UndoStack()
        for i in 0..<10_000 { u.register("edit \(i)") {} }
        try expectEq(u.count, 10_000)
        let top = try unwrap(u.pop())
        try expectEq(top.label, "edit 9999")
    }

    await c.check("a registration interleaving during a group's await is its OWN ⌘Z step") {
        // F3-4: a group body that awaits yields the main actor; an UNRELATED
        // registration arriving in that gap used to fold into the open group
        // (no reentrancy guard) — one ⌘Z would then revert a stranger's edit
        // under the group's label. The group's task-local token now scopes the
        // fold to its own context, so the stranger stands alone.
        let u = UndoStack()
        // Reference box: the group's Task is @Sendable and may not mutate a
        // captured var.
        final class Log { var lines: [String] = [] }
        let log = Log()
        let bodyStarted = Gate()
        let mayFinish = Gate()

        // The group runs in its OWN task, so its task-local token does not
        // leak to the check's task where the stray register() below runs.
        let grouped = Task {
            await u.group("group") {
                u.register("inside") { log.lines.append("inside") }
                await bodyStarted.release()   // "I'm registered and about to park"
                await mayFinish.wait()        // suspend until the stray has landed
            }
        }
        await bodyStarted.wait()
        u.register("stray") { log.lines.append("stray") }   // no group token → its own step
        await mayFinish.release()
        _ = await grouped.value

        try expectEq(u.count, 2, "the stray edit must not fold into the group")
        // The group finalises AFTER the stray was registered, so it sits on
        // top; the point is that the two are SEPARATE steps.
        let top = try unwrap(u.pop())
        try expectEq(top.label, "group", "the completed group sits on top")
        await top.inverse()
        try expectEq(log.lines, ["inside"], "the group holds ONLY its own inverse, not the stray")
        let below = try unwrap(u.pop())
        try expectEq(below.label, "stray")
        await below.inverse()
        try expectEq(log.lines, ["inside", "stray"], "the stray is its own independent ⌘Z step")
    }

    await c.check("edit + follow-on coalesce in ONE group undoes to the exact prior rows") {
        // The 2026-07-09 incident shape, end to end against a fake journal:
        // a save extends slice B to butt against A, the follow-on coalesce
        // fuses them (A survives, B vanishes). With the coalesce's
        // compensating undo registered INSIDE the same group, one ⌘Z must
        // restore both original rows exactly — not leave a fused row.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        let a = Session(task: .op(1), start: t(0), end: t(300), certainty: 0.9, comment: "before")
        let b = Session(task: .op(1), start: t(360), end: t(600), certainty: 1, comment: "edited")
        var journal = [a.id: a, b.id: b]
        let pristine = journal

        let u = UndoStack()
        await u.group("edit") {
            // The edit: B's start dragged back to t300 (now butts A).
            let previous = journal[b.id]!
            u.register("edit") { journal[previous.id] = previous }
            var edited = previous
            edited.start = t(300)
            journal[edited.id] = edited
            // The follow-on coalesce, INSIDE the group (the fix): fuse and
            // register the compensating restore from the plan.
            let original = journal.values.sorted { $0.start < $1.start }
            let merged = TimelineMath.mergeAdjacent(original)
            let plan = TimelineMath.coalescePlan(original: original, merged: merged)
            u.register("merge") {
                for rw in plan.rewrites { journal[rw.prior.id] = rw.prior }
                for row in plan.removed { journal[row.id] = row }
            }
            for row in plan.removed { journal[row.id] = nil }
            for rw in plan.rewrites { journal[rw.merged.id] = rw.merged }
        }
        try expectEq(journal.count, 1, "the save fused A and B")
        try expectEq(u.count, 1, "edit + fusion are ONE ⌘Z step")
        let entry = try unwrap(u.pop())
        await entry.inverse()
        try expectEq(journal, pristine,
                     "one undo restores the exact pre-edit rows, never a fused row")
    }
}

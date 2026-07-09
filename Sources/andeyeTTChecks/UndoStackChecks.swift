import Foundation
import andeyeTTCore

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

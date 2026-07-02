import Foundation
import AmbitickCore

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

    await c.check("pop on an empty stack returns nil") {
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
}

import Foundation
import AmbitickCore

func modelsChecks(_ c: Checks) {
    c.check("version") {
        try expectEq(Ambitick.version, "0.1.0")
    }

    c.check("local tasks are local-only") {
        let local = WorkTask(ref: .local(UUID()), subject: "Gaming", status: "Open")
        let op = WorkTask(ref: .op(42), subject: "Timesheets", status: "Closed")
        try expect(local.isLocalOnly)
        try expect(!op.isLocalOnly)
    }

    c.check("surface prefers URL over title") {
        let withURL = ActivitySignal(app: "Chrome", windowTitle: "Inbox – Gmail",
                                     tabURL: "https://mail.google.com/mail/u/0/#inbox",
                                     timestamp: Date(timeIntervalSince1970: 0))
        try expectEq(Surface(signal: withURL).detail, "mail.google.com/mail/u/0")
        let titled = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick",
                                    timestamp: Date(timeIntervalSince1970: 0))
        try expectEq(Surface(signal: titled), Surface(app: "Ghostty", detail: "Ambitick"))
    }

    c.check("session round-trips through JSON") {
        let s = Session(task: .op(7), start: Date(timeIntervalSince1970: 100),
                        end: Date(timeIntervalSince1970: 700), certainty: 0.83)
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        try expectEq(back, s)
        let r = Session(task: .remote("abc-123"), start: Date(timeIntervalSince1970: 100),
                        end: Date(timeIntervalSince1970: 700), certainty: 0.83)
        try expectEq(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(r)), r)
    }

    c.check("TaskRef wire format is FROZEN — journals/pins/rules/CloudKit depend on it") {
        // These raw literals are the back-compat contract for every journalled
        // row, pins.json, emailrules.json, primed.json and CloudKit revision.
        // If this check ever needs editing, existing user data breaks.
        let dec = JSONDecoder()
        try expectEq(try dec.decode(TaskRef.self, from: Data(#"{"op":{"_0":7}}"#.utf8)), .op(7))
        try expectEq(try dec.decode(TaskRef.self,
                                    from: Data(#"{"remote":{"_0":"abc-123"}}"#.utf8)),
                     .remote("abc-123"))
        let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        try expectEq(try dec.decode(TaskRef.self,
                                    from: Data(#"{"local":{"_0":"\#(uuid.uuidString)"}}"#.utf8)),
                     .local(uuid))
        let encoded = String(data: try JSONEncoder().encode(TaskRef.remote("abc-123")),
                             encoding: .utf8)!
        try expect(encoded.contains(#""remote""#))
    }

    c.check("backendTaskID / isRemote / fallbackLabel / storageKey truth table") {
        let uuid = UUID()
        try expectEq(TaskRef.op(7).backendTaskID, "7")
        try expectEq(TaskRef.remote("g-1").backendTaskID, "g-1")
        try expectEq(TaskRef.local(uuid).backendTaskID, nil)
        try expect(TaskRef.op(7).isRemote && TaskRef.remote("g").isRemote)
        try expect(!TaskRef.local(uuid).isRemote)
        try expectEq(TaskRef.op(7).fallbackLabel, "WP #7")
        try expect(TaskRef.remote("abcdefgh-rest").fallbackLabel.hasPrefix("Task abcdefgh"))
        try expectEq(TaskRef.op(7).storageKey, "op:7")
        try expectEq(TaskRef.remote("g-1").storageKey, "remote:g-1")
        try expectEq(TaskRef.local(uuid).storageKey, "local:\(uuid.uuidString)")
        let remoteTask = WorkTask(ref: .remote("g-1"), subject: "X", status: "ACTIVE")
        try expect(!remoteTask.isLocalOnly)
    }

    c.check("window frame round-trips and decodes legacy (no title)") {
        let f = WindowFrame(bundleID: "com.apple.Safari", x: 10, y: 20, w: 800, h: 600,
                            title: "Inbox – Gmail")
        let back = try JSONDecoder().decode(WindowFrame.self, from: JSONEncoder().encode(f))
        try expectEq(back, f)
        // A layout saved before `title` existed must still decode (title -> "").
        let legacy = #"{"bundleID":"com.apple.Notes","x":1,"y":2,"w":3,"h":4}"#
        let old = try JSONDecoder().decode(WindowFrame.self, from: Data(legacy.utf8))
        try expectEq(old.title, "")
        try expectEq(old.bundleID, "com.apple.Notes")
    }
}

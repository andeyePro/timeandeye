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

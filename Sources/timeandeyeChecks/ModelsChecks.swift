import Foundation
import timeandeyeCore

func modelsChecks(_ c: Checks) {
    c.check("version") {
        try expectEq(Andeye.version, "0.1.0")
    }

    c.check("local tasks are local-only") {
        let local = WorkTask(ref: .local(UUID()), subject: "Gaming", status: "Open")
        let op = WorkTask(ref: .op(42), subject: "Timesheets", status: "Closed")
        try expect(local.isLocalOnly)
        try expect(!op.isLocalOnly)
    }

    c.check("surface prefers URL over title (mail hosts keep their fragment)") {
        let withURL = ActivitySignal(app: "Chrome", windowTitle: "Inbox – Gmail",
                                     tabURL: "https://mail.google.com/mail/u/0/#inbox",
                                     timestamp: Date(timeIntervalSince1970: 0))
        try expectEq(Surface(signal: withURL).detail, "mail.google.com/mail/u/0#inbox")
        let titled = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye",
                                    timestamp: Date(timeIntervalSince1970: 0))
        try expectEq(Surface(signal: titled), Surface(app: "Ghostty", detail: "timeandeye"))
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

    c.check("teachingSignals: every DISTINCT selected surface teaches, repeats teach once, unselected never") {
        // The approvals-drawer spec §1 side-bug: a 40-row multi-select assign
        // taught the attributor from only the FIRST row. The teaching set
        // must cover every selected surface exactly once, in queue order.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let a = ReviewSegment(app: "Chrome", windowTitle: "Gmail", tabURL: "https://mail.google.com",
                              start: t0, end: t0.addingTimeInterval(60))
        let b = ReviewSegment(app: "Chrome", windowTitle: "Gmail", tabURL: "https://mail.google.com",
                              start: t0.addingTimeInterval(120), end: t0.addingTimeInterval(180))
        let d = ReviewSegment(app: "Xcode", windowTitle: "timeandeye",
                              start: t0.addingTimeInterval(240), end: t0.addingTimeInterval(300))
        let unselected = ReviewSegment(app: "Slack", windowTitle: "general",
                                       start: t0.addingTimeInterval(360), end: t0.addingTimeInterval(420))
        let signals = [a, b, d, unselected].teachingSignals(for: [a.id, b.id, d.id])
        try expectEq(signals.count, 2, "a+b share one surface; d is the second; unselected excluded")
        try expectEq(signals[0].app, "Chrome")
        try expectEq(signals[0].timestamp, a.start, "the surface's FIRST row supplies the timestamp")
        try expectEq(signals[1].app, "Xcode")
    }

    c.check("review segment email evidence round-trips JSON; pre-evidence rows decode nil") {
        // Rows written before the evidence keys existed are on real users'
        // disks (the journal keeps review rows indefinitely until assigned) —
        // they must load as evidence-free rows, never fail the whole
        // pendingReview() decode.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let seg = ReviewSegment(app: "Google Chrome", windowTitle: "Gmail",
                                tabURL: "https://mail.google.com/mail/u/0/#inbox/abc",
                                correspondents: ["amy@harborlane.example", "bob@y.co"],
                                emailSubject: "Insurance Renewals",
                                start: t0, end: t0.addingTimeInterval(120))
        let back = try JSONDecoder().decode(ReviewSegment.self, from: JSONEncoder().encode(seg))
        try expectEq(back, seg)
        let legacy = #"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","app":"Mail","start":100,"end":160}"#
        let old = try JSONDecoder().decode(ReviewSegment.self, from: Data(legacy.utf8))
        try expectNil(old.correspondents)
        try expectNil(old.emailSubject)
        try expectEq(old.app, "Mail")
    }

    c.check("teachingSignals: repeats of one surface UNION their email evidence; first subject wins") {
        // The email capture races focus changes, so a later slice of the same
        // surface can hold correspondents (or the subject) an earlier slice
        // missed. The surface's one teaching signal must carry the union —
        // first-seen order, case-insensitive dedup — not whichever slice
        // happened to come first.
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let url = "https://mail.google.com/mail/u/0/#inbox/abc"
        let first = ReviewSegment(app: "Chrome", windowTitle: "Gmail", tabURL: url,
                                  correspondents: ["amy@x.co"],
                                  start: t0, end: t0.addingTimeInterval(60))
        let second = ReviewSegment(app: "Chrome", windowTitle: "Gmail", tabURL: url,
                                   correspondents: ["Amy@x.co", "bob@y.co"],
                                   emailSubject: "Renewal",
                                   start: t0.addingTimeInterval(120), end: t0.addingTimeInterval(180))
        let plain = ReviewSegment(app: "Xcode", windowTitle: "timeandeye",
                                  start: t0.addingTimeInterval(240), end: t0.addingTimeInterval(300))
        let signals = [first, second, plain].teachingSignals(for: [first.id, second.id, plain.id])
        try expectEq(signals.count, 2)
        try expectEq(signals[0].correspondents, ["amy@x.co", "bob@y.co"],
                     "union — the duplicate Amy@x.co folds into the first spelling")
        try expectEq(signals[0].emailSubject, "Renewal", "a later subject fills the empty slot")
        try expectNil(signals[1].correspondents, "a plain surface reconstructs evidence-free")
    }
}

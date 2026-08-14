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

    // Fix 5 of the 2026-08-13 over-learning diagnosis: title-keyed surface
    // identity must survive the app stamping "<sep> <App Name> [version]"
    // into the title — otherwise every app update orphans the persisted
    // primes keyed on the old version string.
    c.check("surface title key drops the app's own trailing signature") {
        let t0 = Date(timeIntervalSince1970: 0)
        // The incident shape: hyphen separator + app name + dotted version.
        let obsidian = ActivitySignal(app: "Obsidian",
                                      windowTitle: "Ambi4-fromMartin - brain2 - Obsidian 1.13.4",
                                      timestamp: t0)
        try expectEq(Surface(signal: obsidian).detail, "Ambi4-fromMartin - brain2")
        // Version bump → SAME surface (the whole point of the fix).
        let updated = ActivitySignal(app: "Obsidian",
                                     windowTitle: "Ambi4-fromMartin - brain2 - Obsidian 1.14.0",
                                     timestamp: t0)
        try expectEq(Surface(signal: obsidian), Surface(signal: updated))
        // App name with no version, other separators, case-insensitive.
        try expectEq(Surface.normalisedTitleKey("draft — Pages", app: "Pages"), "draft")
        try expectEq(Surface.normalisedTitleKey("spec | CODE", app: "Code"), "spec")
        try expectEq(Surface.normalisedTitleKey("plan · Notes v2.1", app: "Notes"), "plan")
        // NOT stripped: tail isn't the app, hyphen without spaces, bare title.
        try expectEq(Surface.normalisedTitleKey("a - b", app: "Obsidian"), "a - b")
        try expectEq(Surface.normalisedTitleKey("Ambi4-fromMartin", app: "Obsidian"),
                     "Ambi4-fromMartin")
        try expectEq(Surface.normalisedTitleKey("", app: "Obsidian"), "")
        // A URL-shaped detail is inert through the migration path.
        try expectEq(Surface.normalisedTitleKey("github.com/foo", app: "Chrome"),
                     "github.com/foo")
    }

    c.check("primed-map legacy keys migrate to normalised surfaces, normalised wins collisions") {
        let raw = Surface(app: "Obsidian", detail: "note - Obsidian 1.13.4")
        let norm = Surface(app: "Obsidian", detail: "note")
        let untouched = Surface(app: "Chrome", detail: "github.com/foo")
        // Raw-only: re-keyed.
        let m1 = Surface.migratingLegacyKeys([raw: .op(1), untouched: .op(2)])
        try expectEq(m1[norm], TaskRef.op(1))
        try expectEq(m1[untouched], TaskRef.op(2))
        try expect(m1[raw] == nil, "the raw key must not survive migration")
        // Collision: the already-normalised entry (the newer write) wins.
        let m2 = Surface.migratingLegacyKeys([raw: .op(1), norm: .op(3)])
        try expectEq(m2[norm], TaskRef.op(3))
        try expectEq(m2.count, 1)
        // Idempotent.
        try expectEq(Surface.migratingLegacyKeys(m1), m1)
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

    c.check("similarity ladder: each rung strictly widens (twins -> title-mates -> app)") {
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        func sig(_ app: String, _ title: String?, _ url: String?) -> ActivitySignal {
            ActivitySignal(app: app, windowTitle: title, tabURL: url, timestamp: t)
        }
        let base = sig("Chrome", "Docs", "https://x.example/1")
        let twin = sig("Chrome", "Docs", "https://x.example/1")
        let titleMate = sig("Chrome", "Docs", "https://x.example/2")
        let appMate = sig("Chrome", "Inbox", nil)
        let stranger = sig("Ghostty", "Docs", nil)
        func matches(_ a: ActivitySignal, _ b: ActivitySignal,
                     at level: SpanSimilarity.Level) -> Bool {
            SpanSimilarity.key(a, at: level) == SpanSimilarity.key(b, at: level)
        }
        // Rung 0: only the exact twin.
        try expect(matches(base, twin, at: .exact))
        try expect(!matches(base, titleMate, at: .exact))
        // Rung 1 admits the title-mate but not the app-mate.
        try expect(matches(base, titleMate, at: .appTitle))
        try expect(!matches(base, appMate, at: .appTitle))
        // Rung 2 admits everything from the app, never another app.
        try expect(matches(base, appMate, at: .app))
        try expect(!matches(base, stranger, at: .app))
        // Superset property: a match at rung N is a match at every rung above.
        for level in SpanSimilarity.Level.allCases.dropFirst() {
            try expect(matches(base, twin, at: level))
        }
        try expect(matches(base, titleMate, at: .app))
    }
}

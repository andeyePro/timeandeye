import Foundation
import timeandeyeCore

/// Decision provenance (2026-07-10, why-panel follow-up): the journal now
/// records WHICH source decided each slice's task, not just what stood.
/// These prove the attribute() branches stamp their source, the tracker
/// carries the decision through holds and manual picks into the flushed
/// session, and the Codable shape is lenient both backwards (old rows
/// without the key) and forwards (an unknown source name survives).
func provenanceChecks(_ c: Checks) {
    let base = Date(timeIntervalSince1970: 1_750_000_080)
    func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "timeandeye", status: "Now"),
                 WorkTask(ref: .op(2), subject: "Investment", status: "Next")]
    func sig(_ app: String, _ title: String, at: TimeInterval, url: String? = nil) -> ActivitySignal {
        ActivitySignal(app: app, windowTitle: title, tabURL: url, timestamp: t(at))
    }

    c.check("attribute() stamps its deciding branch") {
        let a = Attributor(instanceHost: host)
        let opPage = sig("Chrome", "WP 1", at: 0,
                         url: "https://op.example.com/work_packages/1")
        try expectEq(a.attribute(opPage, tasks: tasks, now: t(0)).provenance?.sourceRaw,
                     "opTaskURL")
        let neutral = sig("Preview", "holiday.jpg", at: 0)
        try expectEq(a.attribute(neutral, tasks: tasks, now: t(0)).provenance?.sourceRaw,
                     "ranked")
    }

    c.check("a live-adjacency win carries its reasoning as the detail") {
        let a = Attributor(instanceHost: host)
        let neutral = sig("Preview", "holiday.jpg", at: 0)
        let result = a.attribute(neutral, tasks: tasks, now: t(0),
                                 continuity: .init(target: .task(.op(1)), lastActive: t(0)))
        try expectEq(result.best?.target, .task(.op(1)))
        try expectEq(result.provenance?.sourceRaw, "ranked")
        try expect(result.provenance?.detail?.contains("follows") == true,
                   "the boost's reasoning should be journalled verbatim")
    }

    c.check("flushed session records the deciding source (URL-certain flow)") {
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: TrackerConfig()) { tasks }
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        tracker.handle(.focus(sig("Chrome", "WP 1", at: 0,
                                  url: "https://op.example.com/work_packages/1")))
        tracker.handle(.input(t(60)))
        tracker.stop(at: t(120))
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].provenance?.sourceRaw, "opTaskURL")
    }

    c.check("a manual start journals as userAssigned") {
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: TrackerConfig()) { tasks }
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Preview", "holiday.jpg", at: 1)))
        tracker.handle(.input(t(60)))
        tracker.stop(at: t(120))
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].provenance?.sourceRaw, "userAssigned")
    }

    c.check("session Codable: legacy rows decode with nil provenance") {
        // A pre-2026-07-10 row has no provenance key at all.
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001",
         "task":{"op":{"_0":1}},
         "start":0,"end":600,"certainty":0.9,"pushedToOP":false}
        """
        // TaskRef's real encoding may differ — round-trip a real value
        // instead of guessing, then strip the key.
        let modern = Session(task: .op(1), start: t(0), end: t(600), certainty: 0.9,
                             provenance: SessionProvenance(source: .emailRule,
                                                           detail: "client@x.example"))
        let data = try JSONEncoder().encode(modern)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "provenance")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Session.self, from: stripped)
        try expectNil(decoded.provenance)
        _ = legacy   // shape documented above; the strip test is the real gate
    }

    c.check("session Codable: provenance round-trips, unknown raw survives") {
        let odd = Session(task: .op(1), start: t(0), end: t(600), certainty: 0.9,
                          provenance: SessionProvenance(sourceRaw: "futureSource",
                                                        detail: "x"))
        let decoded = try JSONDecoder().decode(Session.self,
                                               from: JSONEncoder().encode(odd))
        try expectEq(decoded.provenance?.sourceRaw, "futureSource")
        try expectEq(decoded.provenance?.detail, "x")
        try expectNil(decoded.provenance?.source)   // unknown maps to no typed case
        let known = SessionProvenance(source: .pin)
        try expectEq(known.source, .pin)
    }

    c.check("focus span Codable: legacy spans decode with nil provenance") {
        let span = FocusSpan(target: .task(.op(1)), certainty: 0.9,
                             signal: sig("X", "Y", at: 0), start: t(0), end: t(60),
                             provenance: .userAssigned)
        let data = try JSONEncoder().encode(span)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "provenance")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(FocusSpan.self, from: stripped)
        try expectNil(decoded.provenance)
    }

    c.check("focus span Codable: legacy spans decode with observedWhileAway false") {
        // Same strip-the-key idiom as the legacy-provenance case above — a
        // span journalled before 2026-08-07 has no observedWhileAway key at
        // all, and must decode as ordinary (non-away) evidence, not throw.
        let span = FocusSpan(target: .task(.op(1)), certainty: 0.9,
                             signal: sig("X", "Y", at: 0), start: t(0), end: t(60),
                             provenance: .userAssigned)
        let data = try JSONEncoder().encode(span)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "observedWhileAway")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(FocusSpan.self, from: stripped)
        try expectEq(decoded.observedWhileAway, false)

        // Round-trip: a span written WITH the flag set keeps it set.
        let away = FocusSpan(target: .doNotTrack, certainty: 0,
                             signal: sig("X", "Y", at: 0), start: t(0), end: t(60),
                             provenance: SessionProvenance(sourceRaw: "observedWhileAway"),
                             observedWhileAway: true)
        let decodedAway = try JSONDecoder().decode(FocusSpan.self,
                                                    from: JSONEncoder().encode(away))
        try expectEq(decodedAway.observedWhileAway, true)
    }

    c.check("unknown-sweep repoint remembers prior provenance for undo") {
        let session = Session(task: .op(1), start: t(0), end: t(600), certainty: 0.4,
                              provenance: SessionProvenance(source: .ranked))
        let segment = ReviewSegment(app: "X", windowTitle: "Y",
                                    start: t(0), end: t(600))
        let repoints = UnknownSweep.sessionsToRepoint(segments: [segment],
                                                      sessions: [session], bar: 0.9)
        try expectEq(repoints.count, 1)
        try expectEq(repoints[0].priorProvenance?.sourceRaw, "ranked")
    }
}

import Foundation
import andeyeTTCore
import andeyeTTMac

/// D1 acceptance (multidevice-posting spec criterion 1): with sync ON, the
/// pusher bills each session's overlap-RESOLVED contribution — the same
/// seconds the resolved view displays — and a fully-covered session posts
/// nothing. With sync OFF the resolved surface is the raw window (identity),
/// so single-device behaviour is byte-for-byte unchanged (pinned here too).
func resolvedPostingChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func makeStore() throws -> SQLiteJournalStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-resolved-\(UUID().uuidString).sqlite").path
        return try SQLiteJournalStore(path: path)
    }
    var nowMillis: Int64 = 1_750_000_000_000
    func makeClock() -> HLCClock {
        HLCClock(deviceID: "mac") { Date(timeIntervalSince1970: Double(nowMillis) / 1000) }
    }

    await c.check("sync ON: pusher bills the trimmed contribution; view shows the same seconds") {
        let store = try makeStore()
        store.clock = makeClock()
        // Mac auto-tracked 0..3600 on op(1); a synced-in phone MANUAL slice
        // claims 1800..2400 on op(2). Resolution trims auto to 3000 s.
        let auto = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(auto)
        nowMillis += 10
        try store.applyRemote(SessionRevision(
            session: Session(task: .op(2), start: t(1800), end: t(2400), certainty: 1),
            hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .manual))

        // The resolved view: manual untouched, auto in two fragments.
        let view = try store.resolvedSessions(from: t(0), to: t(3600))
        let autoSeconds = view.filter { $0.task == .op(1) }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        try expectEq(autoSeconds, 3000, "display shows the trimmed auto time")

        // The pusher bills exactly those seconds for the auto session.
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let autoCreate = pm.created.first { $0.taskID == "1" }
        try expectEq(autoCreate?.duration, 3000,
                     "posted seconds == displayed seconds (criterion 1)")
        // The snapshot records what was billed, for the D4 detector.
        let row = ((try? store.postingRecord(session: auto.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted)
        try expectEq(row?.postedDuration, 3000)
        try expectEq(row?.postedStart, t(0), "earliest surviving fragment start")
        // The phone's manual slice billed its full span.
        try expectEq(pm.created.first { $0.taskID == "2" }?.duration, 600)
    }

    await c.check("sync ON: a fully-covered session posts NOTHING (skipped, not billed)") {
        let store = try makeStore()
        store.clock = makeClock()
        let auto = Session(task: .op(1), start: t(600), end: t(1200), certainty: 0.95)
        try store.save(auto)
        nowMillis += 10
        // A synced-in EDITED slice (highest authority) covers it entirely.
        try store.applyRemote(SessionRevision(
            session: Session(task: .op(2), start: t(0), end: t(1800), certainty: 1),
            hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .edited))
        try expectNil(try store.resolvedContribution(sessionID: auto.id),
                      "fully covered ⇒ no contribution")

        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        try expectEq(pm.created.filter { $0.taskID == "1" }.count, 0,
                     "covered session billed nothing")
        try expectEq(((try? store.postingRecord(session: auto.id, backendID: "pm-a")) ?? nil)?.state,
                     .skipped, "closed off, never re-attempted")
        try expectEq(pm.created.filter { $0.taskID == "2" }.count, 1,
                     "the covering slice itself billed once")
    }

    await c.check("D4 detection: an edit/trim/delete after posting is counted as divergence") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        let clean = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4000))).first
        try expectEq(clean?.posted, 1)
        try expectEq(clean?.diverged, 0, "fresh post matches the journal")

        // The user trims 30 min off the posted session (an edit path re-saves
        // with a fresh stamp). The backend entry now holds 3600 s of a
        // 1800 s session — that MUST surface, not sit silently wrong.
        nowMillis += 10
        var trimmed = s; trimmed.end = t(1800)
        try store.save(trimmed)
        let after = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4100))).first
        try expectEq(after?.diverged, 1, "duration drift detected")
        try expectEq(after?.posted, 0, "detection never re-posts")
        try expectEq(pm.created.count, 1, "…and never creates a duplicate")

        // Deleting the session entirely: the entry should be retracted —
        // counted as divergence too (retraction is the D4 second half).
        nowMillis += 10
        try store.deleteSession(s.id)
        let gone = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              now: t(4200))).first
        try expectEq(gone?.diverged, 1, "deleted-after-posting detected")
    }

    await c.check("sync OFF: resolved surfaces are the identity — single-device unchanged") {
        let store = try makeStore()   // no clock attached
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        try expectEq(try store.resolvedSessions(from: t(0), to: t(3600)).map(\.id), [s.id])
        let contribution = try store.resolvedContribution(sessionID: s.id)
        try expectEq(contribution?.start, t(0))
        try expectEq(contribution?.seconds, 3600)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        try expectEq(pm.created.first?.duration, 3600, "raw span billed, as ever")
    }
}

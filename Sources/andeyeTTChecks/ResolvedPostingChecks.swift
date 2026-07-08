import Foundation
import SQLite3
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

    await c.check("sync ON: a fully-covered session stays PENDING — and posts when the coverage lifts (A3)") {
        let store = try makeStore()
        store.clock = makeClock()
        let auto = Session(task: .op(1), start: t(600), end: t(1200), certainty: 0.95)
        try store.save(auto)
        nowMillis += 10
        // A synced-in EDITED slice (highest authority) covers it entirely.
        let cover = Session(id: UUID(), task: .op(2), start: t(0), end: t(1800), certainty: 1)
        try store.applyRemote(SessionRevision(
            session: cover,
            hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .edited))
        try expectNil(try store.resolvedContribution(sessionID: auto.id),
                      "fully covered ⇒ no contribution")

        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        try expectEq(pm.created.filter { $0.taskID == "1" }.count, 0,
                     "covered session billed nothing")
        // NOT terminally skipped: a terminal row would strand the hours
        // forever if the covering slice is later deleted.
        try expectNil((try? store.postingRecord(session: auto.id, backendID: "pm-a")) ?? nil,
                      "covered ⇒ pending (no row), releasable")
        try expectEq(pm.created.filter { $0.taskID == "2" }.count, 1,
                     "the covering slice itself billed once")

        // The covering slice is deleted on the other device (tombstone
        // syncs in): the auto session's contribution returns and it POSTS.
        nowMillis += 10
        try store.applyRemote(SessionRevision(
            session: cover,
            hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .edited, deleted: true))
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4200))
        try expectEq(pm.created.filter { $0.taskID == "1" }.count, 1,
                     "coverage lifted ⇒ the stranded time finally bills")
    }

    await c.check("FAIL-CLOSED eligibility: a row in an UNKNOWN future state blocks re-posting (A2)") {
        // A newer build (or a synced ledger from one) writes a state this
        // build doesn't know — say D4's 'diverged'. The row DECODER already
        // reads unknown states as .posted; the eligibility SQL must fail
        // closed the same way, or this build re-posts into possibly-locked
        // books. Write the unknown state with raw SQL (no typed API can).
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-unknown-\(UUID().uuidString).sqlite").path
        let store = try SQLiteJournalStore(path: path)
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        try store.setPostingRecord(PostingRecord(
            sessionID: s.id, backendID: "pm-a", state: .posted, updatedAt: t(100)))
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(path, &db) == SQLITE_OK,
              sqlite3_exec(db, "UPDATE posting_ledger SET state = 'diverged'",
                           nil, nil, nil) == SQLITE_OK else {
            throw CheckFailure(description: "raw state rewrite failed")
        }
        try expectEq(try store.sessions(needingPostTo: "pm-a", atOrAbove: 0.8).count, 0,
                     "unknown state must BLOCK, exactly like the decoder's unknown→posted")
        try expectEq(((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.state,
                     .posted, "decoder direction pinned too")
    }

    await c.check("a list failure HOLDS the claim: inflight stays inflight, posted stays posted (blind spot)") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        // Unresolved intent + unlistable backend: never a blind re-create.
        try store.setPostingRecord(PostingRecord(
            sessionID: s.id, backendID: "pm-a", state: .inflight, updatedAt: t(0),
            sessionStamp: try store.sessionStamp(s.id)))
        pm.failNextLists = 1
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        try expectEq(((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.state,
                     .inflight, "unverifiable intent holds")
        try expectEq(pm.created.count, 0, "no create while the question is open")
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

    await c.check("F13: a resurrected session whose entry was deleted at the backend re-posts exactly once") {
        let store = try makeStore()
        store.clock = makeClock()
        let id = UUID()
        let s = Session(id: id, task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let firstEntry = ((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)?.entryID
        try expectEq(pm.created.count, 1)

        // Device A's story arrives via sync: A tombstoned the session AND
        // deleted the backend entry; then a newer edit on B resurrected it.
        // The stamp must be AFTER the posting row's updatedAt (t+4000) for
        // the touched-since heuristic to see it — wall-clock ordering, as in
        // production where sync always lands after the original post.
        try await pm.deleteTimeEntry(id: try unwrap(firstEntry))
        nowMillis = Int64(t(4100).timeIntervalSince1970 * 1000)
        try store.applyRemote(SessionRevision(
            session: s, hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .edited))

        // Journal says posted; backend holds nothing. The verify sweep must
        // catch it and the SAME pass re-posts — exactly once.
        let report = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                now: t(4200))).first
        try expectEq(report?.posted, 1, "re-posted in the same pass")
        try expectEq(pm.created.count, 2, "exactly one re-create")
        let row = ((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted)
        try expect(row?.entryID != firstEntry, "a fresh entry id was recorded")

        // Control: a touch whose entry IS still present verifies quietly —
        // no re-post, no duplicate, and the row is re-dated so later passes
        // don't re-verify.
        nowMillis = Int64(t(4300).timeIntervalSince1970 * 1000)
        var touched = s; touched.comment = "note added later"
        try store.save(touched)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4400))
        try expectEq(pm.created.count, 2, "present entry: verified, not re-posted")
        let after = ((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)
        try expectEq(after?.state, .posted)
        try expectEq(after?.updatedAt, t(4400), "row re-dated at verification")
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

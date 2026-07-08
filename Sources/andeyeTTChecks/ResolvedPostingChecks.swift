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
        // build doesn't know. The row DECODER already
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
              sqlite3_exec(db, "UPDATE posting_ledger SET state = 'some-future-state'",
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

    await c.check("D4 amendment: a trim after posting UPDATES the backend entry in place") {
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

        // The user trims 30 min off the posted session: the backend must
        // FOLLOW the journal, not sit silently wrong in the books.
        nowMillis = Int64(t(4100).timeIntervalSince1970 * 1000)
        var trimmed = s; trimmed.end = t(1800)
        try store.save(trimmed)
        let after = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4200))).first
        try expectEq(after?.amended, 1, "the drift was propagated")
        try expectEq(after?.diverged, 0, "nothing left disagreeing")
        try expectEq(pm.updated.count, 1)
        try expectEq(pm.updated.first?.duration, 1800, "the trimmed seconds went out")
        try expectEq(pm.created.count, 1, "amendment never creates a duplicate")
        let row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted)
        try expectEq(row?.postedDuration, 1800, "snapshot refreshed to what the backend holds")
        // Quiet afterwards: the next pass amends nothing.
        let again = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4300))).first
        try expectEq(again?.amended, 0)
        try expectEq(pm.updated.count, 1)
    }

    await c.check("D4 amendment: deleting a posted session RETRACTS the backend entry; a restored journal side re-posts") {
        let store = try makeStore()
        store.clock = makeClock()
        let id = UUID()
        let s = Session(id: id, task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let firstEntry = ((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)?.entryID

        nowMillis = Int64(t(4100).timeIntervalSince1970 * 1000)
        try store.deleteSession(id)
        let after = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4200))).first
        try expectEq(after?.retracted, 1)
        try expectEq(pm.deleted, [try unwrap(firstEntry)], "the backend entry was deleted")
        try expectEq(((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)?.state,
                     .retracted)

        // The delete is undone on another device (a newer edit resurrects):
        // the retraction re-opens and the session re-posts exactly once.
        nowMillis = Int64(t(4300).timeIntervalSince1970 * 1000)
        try store.applyRemote(SessionRevision(
            session: s, hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
            origin: .edited))
        let back = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              now: t(4400))).first
        try expectEq(back?.posted, 1, "restored journal side re-posts")
        try expectEq(pm.created.count, 2, "exactly one re-create")
        try expectEq(((try? store.postingRecord(session: id, backendID: "pm-a")) ?? nil)?.state,
                     .posted)
    }

    await c.check("D4 amendment: a FROZEN (invoiced) entry parks .diverged — terminal, surfaced, never retried") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let entryID = try unwrap(((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.entryID)
        pm.frozenIDs = [entryID]

        nowMillis = Int64(t(4100).timeIntervalSince1970 * 1000)
        var trimmed = s; trimmed.end = t(1800)
        try store.save(trimmed)
        let after = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4200))).first
        try expectEq(after?.diverged, 1, "the disagreement is SURFACED, not hidden")
        try expectEq(after?.amended, 0)
        let row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .diverged, "parked for a human")
        // Terminal: the next pass does not retry the frozen entry.
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4300))
        try expectEq(pm.updated.count, 0)
        try expect((try store.sessions(needingPostTo: "pm-a", atOrAbove: 0.8)).isEmpty,
                   "a parked divergence never re-enters the posting queue")
    }

    await c.check("D4 amendment: a backend that can't move an entry in place gets delete+recreate (mustRecreate)") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let firstEntry = try unwrap(((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.entryID)
        pm.recreateOnUpdate = [firstEntry]

        nowMillis = Int64(t(4100).timeIntervalSince1970 * 1000)
        var trimmed = s; trimmed.end = t(1800)
        try store.save(trimmed)
        let after = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t(4200))).first
        try expectEq(after?.amended, 1)
        try expectEq(pm.deleted, [firstEntry], "old entry deleted")
        try expectEq(pm.created.count, 2, "…and recreated at the new shape")
        let row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted)
        try expect(row?.entryID != firstEntry, "the fresh id was recorded")
        try expectEq(row?.postedDuration, 1800)
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

    // MARK: Invoice-lock layer (Martin's proposal, adopted 2026-07-08).
    // A SENT invoice covering posted time locks it in the app: the poll
    // stamps the ref onto the ledger row; from then on the amendment loop
    // must never touch the entry — billed books can't be silently rewritten
    // by a journal edit. Unlock is per invoice, deliberate, and sticky the
    // other way too: the SAME invoice never re-locks itself.

    await c.check("invoice lock: poll stamps the ref; a journal edit then surfaces but NEVER amends billed time") {
        let store = try makeStore()
        store.clock = makeClock()
        var s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let entryID = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.entryID
        try expect(entryID != nil, "posted with an entry id")

        // The backend reports the entry invoiced; the next pass locks it.
        pm.invoiced[entryID!] = "INV-7"
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      now: t(4000 + 1900))
        var row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.lockedInvoiceRef, "INV-7", "poll stamped the invoice ref")

        // The user shortens the session AFTER invoicing: the drift must be
        // SURFACED on the row but the backend entry must stay untouched —
        // no update, no delete, state stays .posted (not demoted).
        nowMillis = Int64(t(6000).timeIntervalSince1970 * 1000)
        s.end = t(1800)
        try store.save(s)
        let reports = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                now: t(4000 + 3900))
        try expectEq(pm.updated.count, 0, "billed time was never amended")
        try expectEq(pm.deleted.count, 0, "billed time was never deleted")
        row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted, "locked row is not demoted")
        try expect(row?.lastError?.contains("INV-7") == true,
                   "the disagreement names the invoice")
        try expectEq(reports.first?.locked, 1, "pass report counts the locked row")
    }

    await c.check("invoice unlock: re-arms amendment, and the SAME ref never re-locks (a NEW invoice does)") {
        let store = try makeStore()
        store.clock = makeClock()
        var s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let entryID = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)!.entryID!
        pm.invoiced[entryID] = "INV-7"
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6000))
        nowMillis = Int64(t(6100).timeIntervalSince1970 * 1000)
        s.end = t(1800)
        try store.save(s)

        // UNLOCK: the guard lifts, the queued drift amends on the next pass.
        engine.unlockInvoice(ref: "INV-7", backendID: "pm-a", now: t(6200))
        var row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectNil(row?.lockedInvoiceRef, "unlock cleared the ref")
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6300))
        try expectEq(pm.updated.first?.duration, 1800, "unlock re-armed the amendment")

        // The backend still reports INV-7 (a void is the accountant's act) —
        // a poll-due pass must NOT re-lock the unlocked invoice…
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6300 + 1900))
        row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectNil(row?.lockedInvoiceRef, "same ref suppressed after unlock")
        // …but a NEW invoice ref locks again as normal.
        pm.invoiced[entryID] = "INV-9"
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6300 + 3900))
        row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.lockedInvoiceRef, "INV-9", "a fresh invoice re-locks")
    }

    await c.check("invoice poll is throttled: back-to-back passes ask the backend once") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let firstPolls = pm.invoicePolls
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4060))
        try expectEq(pm.invoicePolls, firstPolls, "a pass a minute later did not re-poll")
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000 + 1900))
        try expectEq(pm.invoicePolls, firstPolls + 1, "past the interval it polls again")
    }

    // MARK: D6 finance mapping + criterion 10 reopen.

    await c.check("D6 store: source-task lookup goes resolver→mappings; set fires the change signal") {
        let store = FinanceMappingStore(projectKey: { taskID in
            taskID == "42" ? "op/id:7" : nil
        })
        try expectNil(store.mapping(forSourceTask: "42"), "known project, no mapping yet")
        try expectNil(store.mapping(forSourceTask: "999"), "unknown task resolves nothing")
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.set(FinanceMapping(backendProjectID: "xp-1", backendTaskID: "xt-1"),
                  forProjectKey: "op/id:7")
        try expectEq(changed, ["op/id:7"], "set announced the changed key")
        try expectEq(store.mapping(forSourceTask: "42")?.backendProjectID, "xp-1")
        try expectEq(store.mapping(forSourceTask: "42")?.backendTaskID, "xt-1")
    }

    await c.check("criterion 10: the no-mapping skip re-opens when ITS project maps — other skips stay closed") {
        let store = try makeStore()
        store.clock = makeClock()
        let unmapped = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        let gone = Session(task: .op(2), start: t(4000), end: t(5000), certainty: 0.95)
        try store.save(unmapped)
        try store.save(gone)
        let finance = FakeBackend(owns: .op)
        let reason = FinanceMappingStore.noMappingReason(projectKey: "op/id:7")
        finance.permanentReasonOverride["1"] = reason        // D6 unmapped skip
        finance.permanentlyRejects = ["2"]                   // unrelated permanent skip
        let engine = SyncEngine(journal: store, backend: finance, id: "fin-x", class: .finance)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: { _ in true }, now: t(6000))
        try expectEq(((try? store.postingRecord(session: unmapped.id, backendID: "fin-x")) ?? nil)?.state,
                     .skipped, "unmapped task closed .skipped, queue proceeded")
        try expectEq(((try? store.postingRecord(session: unmapped.id, backendID: "fin-x")) ?? nil)?.lastError,
                     reason, "the skip reason IS the reopen key, verbatim")

        // A mapping lands for a DIFFERENT project: nothing re-opens.
        SyncEngine.reopenMappingSkips(journal: store, backendID: "fin-x",
                                      projectKey: "op/id:99")
        try expectEq(((try? store.postingRecord(session: unmapped.id, backendID: "fin-x")) ?? nil)?.state,
                     .skipped, "someone else's mapping changes nothing")

        // THE project maps (the store's change handler is the trigger, as
        // the controller wires it): exactly this skip clears; the session
        // posts on the very next pass; the unrelated skip stays closed.
        let mappings = FinanceMappingStore(projectKey: { $0 == "1" ? "op/id:7" : nil })
        mappings.onChange = { key in
            SyncEngine.reopenMappingSkips(journal: store, backendID: "fin-x", projectKey: key)
        }
        mappings.set(FinanceMapping(backendProjectID: "xp-1", backendTaskID: "xt-1"),
                     forProjectKey: "op/id:7")
        try expectNil((try? store.postingRecord(session: unmapped.id, backendID: "fin-x")) ?? nil,
                      "the no-mapping skip cleared — session re-enters the queue")
        finance.permanentReasonOverride = [:]   // the connector now maps it
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: { _ in true }, now: t(6100))
        try expectEq(finance.created.filter { $0.taskID == "1" }.count, 1,
                     "mapped ⇒ posted on the next pass")
        try expectEq(((try? store.postingRecord(session: gone.id, backendID: "fin-x")) ?? nil)?.state,
                     .skipped, "the task-gone skip never re-opened")
    }

    await c.check("a locked row whose entry vanished is NOT demoted for re-post (no duplicate of billed time)") {
        let store = try makeStore()
        store.clock = makeClock()
        var s = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)
        try store.save(s)
        let pm = FakeBackend(owns: .op)
        let engine = SyncEngine(journal: store, backend: pm, id: "pm-a", class: .pm)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(4000))
        let entryID = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)!.entryID!
        pm.invoiced[entryID] = "INV-7"
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6000))
        // The entry disappears from the backend's list AND the session is
        // touched — the resurrection sweep would normally demote for a
        // re-post; on a locked row that would duplicate invoiced time.
        pm.held.removeAll()
        nowMillis = Int64(t(6100).timeIntervalSince1970 * 1000)
        s.comment = "touched"
        try store.save(s)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false, now: t(6200))
        let row = ((try? store.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted, "locked row held its claim")
        try expectEq(pm.created.count, 1, "no duplicate create")
    }
}

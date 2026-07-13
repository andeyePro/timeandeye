import Foundation
import timeandeyeCore
import timeandeyeMac

// MARK: - MultiDevicePostingChecks: the money invariants across TWO devices
//
// The worst money bug lives here: two Macs share ONE journal via CloudKit, but
// each keeps its OWN posting ledger (the posting_ledger table is device-local
// — CloudKitSyncTransport ships SessionRevisions, never ledger rows). So both
// devices independently see the same eligible slice and, without a guard, both
// create a remote entry for it → the same time billed twice. The guard is
// D2(a): exactly one device owns posting for a backend (postingOwners +
// localDeviceID); non-owners track/edit/read but never touch the wire.
//
// FIDELITY — what this harness CAPTURES faithfully:
//   • two independent journals (separate SQLite files, separate HLC clocks
//     with distinct deviceIDs) = two independent device-local posting ledgers,
//     which is the real double-post surface;
//   • ONE shared FakeBackend instance both engines post/list/delete against =
//     the single remote truth two devices converge on;
//   • sessions propagate device→device as SessionRevisions applied through
//     `applyRemote` — the EXACT store entry point CloudKitSyncTransport feeds
//     on pull, carrying the author's HLC (so `sessionStamp`/`stampChanged`
//     see genuine cross-device revision changes);
//   • the D2(a) owner gate as the sole cross-device double-post guard, and the
//     stamp-driven resurrection/divergence machinery (verifyTouchedPosted /
//     amendDiverged's retract + reopen) reacting to a remote edit.
//
// What it APPROXIMATES (and why that is sound here):
//   • it hand-propagates the revision each device would have pulled rather than
//     running JournalSyncer.sync() through a live transport — SessionMerge's
//     conflict resolution is exercised in JournalSyncerChecks; the money
//     invariants below turn on the two ledgers and the owner gate, not on the
//     merge tie-breaks;
//   • passes run in an explicit interleave, not on real concurrent threads —
//     the risk being modelled is two independent ledgers racing to post the
//     same slice, which the interleave reproduces exactly; the engine itself
//     serialises pass-vs-pass within a device (PostingMachineChecks' remit).
func multiDevicePostingChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let backendID = OPBackend.stableID   // the pm ledger key both devices share

    // A monotonic HLC minter standing in for CloudKit's causal order: every
    // revision (a local edit or one synced in from the peer) gets a strictly
    // newer stamp, which is all `stampChanged` compares.
    var hlcMillis: Int64 = 1_750_000_000_000
    func stamp(_ device: String) -> HLC {
        hlcMillis += 10
        return HLC(physicalMillis: hlcMillis, counter: 0, deviceID: device)
    }

    func makeStore(_ device: String) throws -> SQLiteJournalStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-multidev-\(device)-\(UUID().uuidString).sqlite").path
        let store = try SQLiteJournalStore(path: path)
        // A clock (sync ON) so resolvedContribution engages the overlap-resolved
        // path and stamps are live — the multi-device regime, never sync-off.
        store.clock = HLCClock(deviceID: device) {
            Date(timeIntervalSince1970: Double(hlcMillis) / 1000)
        }
        return store
    }

    func device(_ store: SQLiteJournalStore, _ id: String, owner: String,
                backend: FakeBackend) -> SyncEngine {
        let engine = SyncEngine(journal: store, backend: backend, id: backendID, class: .pm)
        engine.localDeviceID = id
        engine.postingOwners = [backendID: owner]
        return engine
    }

    // Live remote entries the backend holds for one task = that cell's live
    // entries ACROSS every device pointed at it; more than one is a double-post.
    func live(_ backend: FakeBackend, _ taskID: String) -> Int {
        backend.held.filter { $0.taskID == taskID }.count
    }
    func cell(_ store: SQLiteJournalStore, _ id: UUID) -> PostingRecord? {
        ((try? store.postingRecord(session: id, backendID: backendID)) ?? nil)
    }

    let slice = Session(task: .op(1), start: t(0), end: t(3600), certainty: 0.95)

    // ===================================================================
    // M1 cross-device — one live entry across TWO devices. Both hold the same
    // synced slice; only the owner posts. The non-owner running its pass in
    // between must NOT create a rival entry.
    // ===================================================================

    await c.check("M1 cross-device: two synced devices post ONE remote entry — the non-owner defers to the owner") {
        let macA = try makeStore("mac-a"); let macB = try makeStore("mac-b")
        let backend = FakeBackend(owns: .op)
        let engA = device(macA, "mac-a", owner: "mac-a", backend: backend)   // owner
        let engB = device(macB, "mac-b", owner: "mac-a", backend: backend)   // non-owner

        // Device A authored the slice; it synced to B — both hold the identical
        // revision, so both queues would post it absent the ownership gate.
        let rev = SessionRevision(session: slice, hlc: stamp("mac-a"), origin: .auto)
        try macA.applyRemote(rev); try macB.applyRemote(rev)

        // Interleave: non-owner first (proves it creates nothing), then the
        // owner, then the non-owner again (proves it never doubles after).
        let rB1 = await engB.pushEligible(threshold: 0.8, includeComments: false, now: t(20000))
        try expectEq(rB1.first?.notOwner, true, "the non-owner does nothing — no rival create")
        try expectEq(live(backend, "1"), 0, "nobody has posted yet")
        try expectNil(cell(macB, slice.id), "the non-owner writes NO ledger row — the slice stays pending for the owner")

        let rA = await engA.pushEligible(threshold: 0.8, includeComments: false, now: t(20001))
        try expectEq(rA.first?.posted, 1, "the owner posts exactly once")
        try expectEq(live(backend, "1"), 1)

        _ = await engB.pushEligible(threshold: 0.8, includeComments: false, now: t(20002))
        // THE money invariant: after BOTH devices have run, one live entry.
        try expectEq(live(backend, "1"), 1, "M1 cross-device: never two live entries for one slice")
        try expectEq(backend.created.count, 1, "exactly one create across both devices")
        try expectEq(cell(macA, slice.id)?.state, .posted)
        try expectNil(cell(macB, slice.id), "the non-owner still holds no ledger row of its own")
    }

    // ===================================================================
    // Cross-device delete (M4 across the pair) — a slice deleted on one device
    // must retract its billed entry, handled by the OWNER, and must never be
    // re-posted. The non-owner where the delete happened touches nothing.
    // ===================================================================

    await c.check("cross-device delete: a slice deleted on device A retracts at the backend via owner device B — never re-posted") {
        let macA = try makeStore("mac-a"); let macB = try makeStore("mac-b")
        let backend = FakeBackend(owns: .op)
        let engA = device(macA, "mac-a", owner: "mac-b", backend: backend)   // non-owner
        let engB = device(macB, "mac-b", owner: "mac-b", backend: backend)   // owner

        let rev = SessionRevision(session: slice, hlc: stamp("mac-a"), origin: .auto)
        try macA.applyRemote(rev); try macB.applyRemote(rev)

        // The owner posts the slice once.
        _ = await engB.pushEligible(threshold: 0.8, includeComments: false, now: t(20000))
        try expectEq(live(backend, "1"), 1)

        // Device A (NOT the owner) deletes the slice locally; its own pass must
        // leave the backend entry untouched — a non-owner never retracts.
        try macA.deleteSession(slice.id)
        let rA = await engA.pushEligible(threshold: 0.8, includeComments: false, now: t(20001))
        try expectEq(rA.first?.notOwner, true)
        try expectEq(live(backend, "1"), 1, "the non-owner never retracts billed time")

        // The tombstone syncs to the owner: its convergence loop retracts the
        // entry (billed time must not outlive its session) and never re-posts.
        try macB.applyRemote(SessionRevision(session: slice, hlc: stamp("mac-a"),
                                             origin: .auto, deleted: true))
        let rB = await engB.pushEligible(threshold: 0.8, includeComments: false, now: t(20002))
        try expectEq(live(backend, "1"), 0, "billed time never outlives its session (M4 across devices)")
        try expect((rB.first?.retracted ?? 0) >= 1, "the owner retracted the entry")
        try expectEq(backend.created.count, 1, "retract, not re-post: exactly one create ever")
        try expectEq(cell(macB, slice.id)?.state, .retracted)
    }

    // ===================================================================
    // Cross-device resurrection — the stamp-driven divergence path. A slice is
    // posted, deleted (retracted) from a peer, then RESURRECTED by a newer peer
    // edit. The owner re-bills it EXACTLY once: a fresh entry, never a second
    // live entry over the (dead) original. This is the invisible inverse of the
    // double-post — the sessionStamp comparison is what resolves it.
    // ===================================================================

    await c.check("cross-device resurrection: a deleted-then-resurrected slice re-posts ONCE — a new entry, never a duplicate") {
        let macA = try makeStore("mac-a")
        let backend = FakeBackend(owns: .op)
        let engA = device(macA, "mac-a", owner: "mac-a", backend: backend)   // owner

        try macA.applyRemote(SessionRevision(session: slice, hlc: stamp("mac-a"), origin: .auto))
        _ = await engA.pushEligible(threshold: 0.8, includeComments: false, now: t(20000))
        let firstEntry = cell(macA, slice.id)?.entryID
        try expect(firstEntry != nil, "the slice posted first")
        try expectEq(live(backend, "1"), 1)

        // A peer deletes the slice; the tombstone syncs in and the owner
        // retracts what it posted (stamp changed → divergence → retract).
        try macA.applyRemote(SessionRevision(session: slice, hlc: stamp("mac-b"),
                                             origin: .auto, deleted: true))
        _ = await engA.pushEligible(threshold: 0.8, includeComments: false, now: t(20100))
        try expectEq(live(backend, "1"), 0, "the retract landed")
        try expectEq(cell(macA, slice.id)?.state, .retracted)

        // The peer RESURRECTS it (a newer edit un-deletes the slice) and syncs
        // back. The owner's stamp-driven reopen re-posts it exactly once.
        try macA.applyRemote(SessionRevision(session: slice, hlc: stamp("mac-b"),
                                             origin: .edited, deleted: false))
        _ = await engA.pushEligible(threshold: 0.8, includeComments: false, now: t(20200))
        try expectEq(live(backend, "1"), 1, "resurrected slice is billed again — exactly one live entry")
        try expectEq(cell(macA, slice.id)?.state, .posted)
        let secondEntry = cell(macA, slice.id)?.entryID
        try expect(secondEntry != nil && secondEntry != firstEntry,
                   "a NEW entry — the dead one was never resurrected by its stale id")
        try expectEq(backend.created.count, 2,
                     "one create per genuine posting; never a second live entry over the first")
    }
}

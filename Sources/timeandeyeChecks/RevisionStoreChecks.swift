import Foundation
import timeandeyeCore
import timeandeyeMac

/// Conformance suite every RevisionStore implementation must pass (mirrors
/// journalStoreConformanceChecks): the sync layer's correctness rests on
/// these invariants holding identically on the in-memory and SQLite replicas.
func revisionStoreConformanceChecks(_ c: Checks, name: String,
                                    make: () -> any RevisionStore) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func rev(_ id: UUID = UUID(), millis: Int64, device: String = "mac",
             deleted: Bool = false, origin: SliceOrigin = .auto) -> SessionRevision {
        SessionRevision(session: Session(id: id, task: .op(1), start: t0,
                                         end: t0.addingTimeInterval(600), certainty: 0.9),
                        hlc: HLC(physicalMillis: millis, counter: 0, deviceID: device),
                        origin: origin, deleted: deleted)
    }

    c.check("[\(name)] saveLocal dirties; applyRemote doesn't; round-trips") {
        let s = make()
        let local = rev(millis: 1)
        let remote = rev(millis: 2, device: "phone", origin: .manual)
        try s.saveLocal(local)
        try s.applyRemote(remote)
        try expectEq(try s.dirtyRevisionIDs(), [local.id])
        try expectEq(try s.revision(id: local.id), local)
        try expectEq(try s.revision(id: remote.id), remote)
        try expectEq(try s.allRevisions().count, 2)
    }

    c.check("[\(name)] applyRemote over a dirty local clears its dirtiness") {
        let s = make()
        let id = UUID()
        try s.saveLocal(rev(id, millis: 1))
        try s.applyRemote(rev(id, millis: 5, device: "phone"))
        try expectEq(try s.dirtyRevisionIDs(), [], "the remote won; nothing to push")
    }

    c.check("[\(name)] clearDirty is HLC-matched: a mid-push edit stays dirty") {
        let s = make()
        let id = UUID()
        let pushed = rev(id, millis: 1)
        try s.saveLocal(pushed)
        // An edit lands between the syncer reading `pushed` and clearing it.
        let edited = rev(id, millis: 2)
        try s.saveLocal(edited)
        try s.clearDirty([pushed])
        try expectEq(try s.dirtyRevisionIDs(), [id], "newer revision must stay dirty")
        try s.clearDirty([edited])
        try expectEq(try s.dirtyRevisionIDs(), [])
    }

    c.check("[\(name)] tombstones are stored and returned") {
        let s = make()
        let dead = rev(millis: 3, deleted: true)
        try s.applyRemote(dead)
        try expectEq(try s.revision(id: dead.id)?.deleted, true)
        try expectEq(try s.allRevisions().filter(\.deleted).count, 1)
    }

    c.check("[\(name)] sync token round-trips") {
        let s = make()
        try expectNil(s.syncToken)
        s.syncToken = SyncToken(raw: Data("42".utf8))
        try expectEq(s.syncToken, SyncToken(raw: Data("42".utf8)))
    }
}

/// SQLite-specific: the JournalStore mutation paths stamp/tombstone correctly
/// when the clock is attached, and excluded rows never enter the sync world.
func sqliteSyncStampingChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func makeStore() throws -> SQLiteJournalStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-sync-\(UUID().uuidString).sqlite").path
        return try SQLiteJournalStore(path: path)
    }
    var nowMillis: Int64 = 1_750_000_000_000
    func makeClock() -> HLCClock {
        HLCClock(deviceID: "mac") { Date(timeIntervalSince1970: Double(nowMillis) / 1000) }
    }
    func session(_ id: UUID = UUID()) -> Session {
        Session(id: id, task: .op(1), start: t0, end: t0.addingTimeInterval(600), certainty: 0.9)
    }

    c.check("clock attached: save stamps + dirties; delete becomes a travelling tombstone") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = session()
        try store.save(s)
        let rev = try unwrap(try store.revision(id: s.id))
        try expect(!rev.hlc.deviceID.isEmpty, "stamped")
        try expectEq(try store.dirtyRevisionIDs(), [s.id])
        try store.deleteSession(s.id)
        try expectEq(try store.allSessions(), [], "tombstone hidden from journal reads")
        try expectEq(try store.session(id: s.id), nil)
        let dead = try unwrap(try store.revision(id: s.id))
        try expect(dead.deleted, "revision survives as a tombstone")
        try expect(rev.hlc < dead.hlc, "the delete re-stamped")
        // markPushed is a mutation too: it must re-stamp and re-dirty.
        let s2 = session()
        try store.save(s2)
        let before = try unwrap(try store.revision(id: s2.id)).hlc
        try store.clearDirty([try unwrap(try store.revision(id: s2.id))])
        try store.markPushed(s2.id, opTimeEntryID: "977")
        let after = try unwrap(try store.revision(id: s2.id))
        try expect(before < after.hlc)
        try expect(try store.dirtyRevisionIDs().contains(s2.id))
        try expectEq(after.session.opTimeEntryID, "977")
    }

    c.check("no clock: behaviour unchanged — hard delete, nothing enters the sync world") {
        let store = try makeStore()
        let s = session()
        try store.save(s)
        try expectEq(try store.allRevisions(), [], "unstamped rows are not revisions")
        try store.deleteSession(s.id)
        try expectEq(try store.revision(id: s.id), nil, "hard-deleted")
        try expectEq(try store.sessionCount(), 0)
    }

    c.check("excluded row (live checkpoint): unstamped, hard-deleted, invisible to sync") {
        let store = try makeStore()
        store.clock = makeClock()
        let checkpoint = session()
        store.syncExcludedIDs = [checkpoint.id]
        try store.save(checkpoint)
        try store.save(session())   // a normal row alongside
        try expectEq(try store.allRevisions().count, 1)
        try expectEq(try store.dirtyRevisionIDs().count, 1)
        try expectNil(try store.revision(id: checkpoint.id))
        try store.deleteSession(checkpoint.id)
        try expectEq(try store.sessionCount(), 1, "checkpoint hard-deleted")
    }

    c.check("escalateOrigin promotes, re-stamps and dirties — and never downgrades") {
        let store = try makeStore()
        store.clock = makeClock()
        let s = session()
        try store.save(s)
        let auto = try unwrap(try store.revision(id: s.id))
        try expectEq(auto.origin, .auto)
        try store.escalateOrigin(s.id, to: .edited)
        let edited = try unwrap(try store.revision(id: s.id))
        try expectEq(edited.origin, .edited)
        try expect(auto.hlc < edited.hlc, "origin change must sync, so it re-stamps")
        try store.escalateOrigin(s.id, to: .manual)   // downgrade attempt
        try expectEq(try store.revision(id: s.id)?.origin, .edited,
                     "edited never downgrades to manual")
        try expectEq(try store.revision(id: s.id)?.hlc, edited.hlc,
                     "a refused downgrade is a no-op, not a new revision")
        // Clock state persists across a store re-open (monotonic restarts).
        try expect(store.loadClockState() != nil, "clock state persisted")
    }

    c.check("stampAllUnstamped migrates pre-sync rows once, in start order") {
        let store = try makeStore()
        let early = Session(task: .op(1), start: t0, end: t0.addingTimeInterval(600), certainty: 0.9)
        let late = Session(task: .op(2), start: t0.addingTimeInterval(1000),
                           end: t0.addingTimeInterval(1600), certainty: 0.9)
        try store.save(late)    // insert order ≠ start order, deliberately
        try store.save(early)
        let clock = makeClock()
        store.clock = clock
        try store.stampAllUnstamped(clock: clock)
        let revs = try store.allRevisions()
        try expectEq(revs.count, 2)
        try expectEq(try store.dirtyRevisionIDs().count, 2, "everything queued for first upload")
        let earlyRev = try unwrap(revs.first { $0.id == early.id })
        let lateRev = try unwrap(revs.first { $0.id == late.id })
        try expect(earlyRev.hlc < lateRev.hlc, "stamped in start order")
        let stamp = earlyRev.hlc
        try store.stampAllUnstamped(clock: clock)
        try expectEq(try store.revision(id: early.id)?.hlc, stamp, "idempotent")
    }

    c.check("is_op column semantics FROZEN: 1 = remote/pushable (.op AND .remote), 0 = .local") {
        let store = try makeStore()
        let opS = session()
        let remoteS = Session(task: .remote("g-1"), start: t0,
                              end: t0.addingTimeInterval(600), certainty: 0.9)
        let localS = Session(task: .local(UUID()), start: t0,
                             end: t0.addingTimeInterval(600), certainty: 0.9)
        try store.save(opS)
        try store.save(remoteS)
        try store.save(localS)
        // The raw column, not query behaviour — the freeze is the contract.
        for (id, want) in [(opS.id, 1), (remoteS.id, 1), (localS.id, 0)] {
            let got = try store.rawIsOPColumn(id: id)
            try expectEq(got, want, "is_op for \(id)")
        }
    }

    c.check("tombstone GC: purges old synced tombstones only") {
        let store = try makeStore()
        store.clock = makeClock()
        let now = Date(timeIntervalSince1970: Double(nowMillis) / 1000)
        func tombstone(_ ageDays: Double, dirty: Bool) throws -> UUID {
            let s = session()
            let hlc = HLC(physicalMillis: nowMillis - Int64(ageDays * 86_400 * 1000),
                          counter: 0, deviceID: "mac")
            let rev = SessionRevision(session: s, hlc: hlc, origin: .auto, deleted: true)
            if dirty { try store.saveLocal(rev) } else { try store.applyRemote(rev) }
            return s.id
        }
        let oldSynced = try tombstone(120, dirty: false)     // purged
        let oldUnpushed = try tombstone(120, dirty: true)    // MUST survive
        let recent = try tombstone(10, dirty: false)         // survives
        let live = session()
        try store.save(live)                                  // untouched
        try store.purgeTombstones(olderThanDays: 90, now: now)
        try expectNil(try store.revision(id: oldSynced), "old synced tombstone purged")
        try expectEq(try store.revision(id: oldUnpushed)?.deleted, true,
                     "an unpushed delete must survive or it never travels")
        try expectEq(try store.revision(id: recent)?.deleted, true)
        try expectEq(try store.session(id: live.id)?.id, live.id, "live rows untouched")
    }

    c.check("a synced SQLite replica converges with an in-memory one end-to-end") {
        let server = MockSyncServer()
        let sqlite = try makeStore()
        let sqliteClock = makeClock()
        sqlite.clock = sqliteClock
        let phoneStore = InMemoryRevisionStore()
        let phoneClock = HLCClock(deviceID: "phone") {
            Date(timeIntervalSince1970: Double(nowMillis) / 1000)
        }
        let macSync = JournalSyncer(store: sqlite, transport: server, clock: sqliteClock)
        let phoneSync = JournalSyncer(store: phoneStore, transport: server, clock: phoneClock)

        try sqlite.save(session())                       // normal Mac tracking write
        nowMillis += 10
        try phoneStore.saveLocal(SessionRevision(
            session: Session(task: .op(2), start: t0.addingTimeInterval(2000),
                             end: t0.addingTimeInterval(2600), certainty: 1),
            hlc: phoneClock.tick(), origin: .manual))

        let semaphore = DispatchSemaphore(value: 0)
        // Reference box: the Task closure is @Sendable and may not mutate a
        // captured var.
        final class ErrorBox { var error: Error? }
        let thrown = ErrorBox()
        Task {
            do {
                try await macSync.sync()
                try await phoneSync.sync()
                try await macSync.sync()
                try await phoneSync.sync()
            } catch { thrown.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = thrown.error { throw error }
        try expectEq(try sqlite.allRevisions(), try phoneStore.allRevisions(),
                     "SQLite and in-memory replicas hold the identical raw set")
        try expectEq(try sqlite.allSessions().count, 2, "the phone's slice landed in the journal")
    }
}

import Foundation
import AmbitickCore

/// In-memory stand-in for the CloudKit private zone: record-level LWW via the
/// SAME SessionMerge the replicas use, with a monotonically increasing change
/// sequence as the pull cursor.
final class MockSyncServer: SyncTransport {
    private var records: [UUID: (rev: SessionRevision, seq: Int)] = [:]
    private var seq = 0
    private(set) var pushCount = 0

    func push(_ revisions: [SessionRevision]) async throws {
        pushCount += 1
        for rev in revisions {
            let winner = SessionMerge.merge(local: records[rev.id]?.rev, remote: rev)
            guard let winner, winner == rev else { continue }   // server copy newer
            seq += 1
            records[rev.id] = (rev, seq)
        }
    }

    func pull(since token: SyncToken?) async throws -> (changes: [SessionRevision], token: SyncToken) {
        let after = token.flatMap { Int(String(data: $0.raw, encoding: .utf8) ?? "") } ?? 0
        let changed = records.values.filter { $0.seq > after }
            .sorted { $0.seq < $1.seq }
            .map(\.rev)
        return (changed, SyncToken(raw: Data(String(seq).utf8)))
    }
}

func journalSyncerChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A device: store + clock + syncer bound to the shared server.
    func device(_ id: String, server: MockSyncServer,
                nowMillis: @escaping () -> Int64) -> (InMemoryRevisionStore, HLCClock, JournalSyncer) {
        let store = InMemoryRevisionStore()
        let clock = HLCClock(deviceID: id) { Date(timeIntervalSince1970: Double(nowMillis()) / 1000) }
        return (store, clock, JournalSyncer(store: store, transport: server, clock: clock))
    }

    func liveSessions(_ store: InMemoryRevisionStore) throws -> [SessionRevision] {
        SessionMerge.resolveOverlaps(try store.allRevisions()).filter { !$0.deleted }
    }

    await c.check("two replicas converge to identical raw sets and views") {
        var millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (macStore, macClock, macSync) = device("mac", server: server) { millis }
        let (phoneStore, phoneClock, phoneSync) = device("phone", server: server) { millis }

        // Mac auto-tracks 0..600; phone manually tracks 1000..1600. Offline.
        let macSession = Session(task: .op(1), start: t(0), end: t(600), certainty: 0.9)
        try macStore.saveLocal(SessionRevision(session: macSession, hlc: macClock.tick(),
                                               origin: .auto))
        millis += 10
        let phoneSession = Session(task: .op(2), start: t(1000), end: t(1600), certainty: 1)
        try phoneStore.saveLocal(SessionRevision(session: phoneSession, hlc: phoneClock.tick(),
                                                 origin: .manual))

        // Both sync twice (push then see each other's pushes).
        try await macSync.sync()
        try await phoneSync.sync()
        try await macSync.sync()
        try await phoneSync.sync()

        try expectEq(try macStore.allRevisions(), try phoneStore.allRevisions(),
                     "identical raw sets")
        try expectEq(try liveSessions(macStore).count, 2)
    }

    await c.check("conflicting edits of one slice: newer HLC wins on both replicas") {
        var millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (macStore, macClock, macSync) = device("mac", server: server) { millis }
        let (phoneStore, phoneClock, phoneSync) = device("phone", server: server) { millis }

        // A shared slice, fully synced.
        let id = UUID()
        let original = Session(id: id, task: .op(1), start: t(0), end: t(600), certainty: 0.9)
        try macStore.saveLocal(SessionRevision(session: original, hlc: macClock.tick(),
                                               origin: .auto))
        try await macSync.sync()
        try await phoneSync.sync()
        try expectEq(try phoneStore.revision(id: id)?.session, original)

        // Both edit offline: mac first, phone later (later physical time).
        millis += 10
        var macEdit = original; macEdit.end = t(900)
        try macStore.saveLocal(SessionRevision(session: macEdit, hlc: macClock.tick(),
                                               origin: .edited))
        millis += 10
        var phoneEdit = original; phoneEdit.comment = "from the phone"
        try phoneStore.saveLocal(SessionRevision(session: phoneEdit, hlc: phoneClock.tick(),
                                                 origin: .edited))

        try await macSync.sync()
        try await phoneSync.sync()
        try await macSync.sync()

        try expectEq(try macStore.allRevisions(), try phoneStore.allRevisions())
        try expectEq(try macStore.revision(id: id)?.session.comment, "from the phone",
                     "the later edit won everywhere")
        try expectEq(try macStore.revision(id: id)?.session.end, t(600),
                     "LWW is whole-record: the losing edit's field does not survive")
    }

    await c.check("a delete travels; a later edit resurrects") {
        var millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (macStore, macClock, macSync) = device("mac", server: server) { millis }
        let (phoneStore, phoneClock, phoneSync) = device("phone", server: server) { millis }

        let id = UUID()
        let s = Session(id: id, task: .op(1), start: t(0), end: t(600), certainty: 0.9)
        try macStore.saveLocal(SessionRevision(session: s, hlc: macClock.tick(), origin: .auto))
        try await macSync.sync()
        try await phoneSync.sync()

        // Mac deletes; phone pulls the tombstone.
        millis += 10
        try macStore.saveLocal(SessionRevision(session: s, hlc: macClock.tick(),
                                               origin: .auto, deleted: true))
        try await macSync.sync()
        try await phoneSync.sync()
        try expectEq(try phoneStore.revision(id: id)?.deleted, true, "tombstone travelled")
        try expectEq(try liveSessions(phoneStore).count, 0)

        // Phone re-instates (a deliberate later edit) — mac sees it live again.
        millis += 10
        try phoneStore.saveLocal(SessionRevision(session: s, hlc: phoneClock.tick(),
                                                 origin: .edited))
        try await phoneSync.sync()
        try await macSync.sync()
        try expectEq(try macStore.revision(id: id)?.deleted, false, "resurrected")
    }

    await c.check("push echoes are idempotent; nothing stays dirty after a clean cycle") {
        let millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (store, clock, syncer) = device("mac", server: server) { millis }
        try store.saveLocal(SessionRevision(
            session: Session(task: .op(1), start: t(0), end: t(600), certainty: 0.9),
            hlc: clock.tick(), origin: .auto))
        try await syncer.sync()
        try await syncer.sync()   // pulls its own echo
        try await syncer.sync()
        try expectEq(try store.dirtyRevisionIDs(), [])
        try expectEq(try store.allRevisions().count, 1, "echo did not duplicate")
        try expectEq(server.pushCount, 1, "no re-push of clean records")
    }

    await c.check("dirty local that wins LWW survives the pull and gets pushed") {
        var millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (macStore, macClock, macSync) = device("mac", server: server) { millis }
        let (phoneStore, phoneClock, phoneSync) = device("phone", server: server) { millis }

        let id = UUID()
        let s = Session(id: id, task: .op(1), start: t(0), end: t(600), certainty: 0.9)
        try macStore.saveLocal(SessionRevision(session: s, hlc: macClock.tick(), origin: .auto))
        try await macSync.sync()
        try await phoneSync.sync()

        // Phone edits and pushes; mac edits LATER but hasn't synced yet.
        millis += 10
        var phoneEdit = s; phoneEdit.comment = "phone"
        try phoneStore.saveLocal(SessionRevision(session: phoneEdit, hlc: phoneClock.tick(),
                                                 origin: .edited))
        try await phoneSync.sync()
        millis += 10
        var macEdit = s; macEdit.comment = "mac, newer"
        try macStore.saveLocal(SessionRevision(session: macEdit, hlc: macClock.tick(),
                                               origin: .edited))

        // Mac's cycle pulls the phone edit (older, loses) then pushes its own.
        try await macSync.sync()
        try await phoneSync.sync()
        try expectEq(try phoneStore.revision(id: id)?.session.comment, "mac, newer")
        try expectEq(try macStore.allRevisions(), try phoneStore.allRevisions())
    }
}

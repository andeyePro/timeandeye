import Foundation
import timeandeyeCore

/// In-memory stand-in for the CloudKit private zone. TRUTHFUL to CloudKit's
/// `.allKeys` save policy: a push OVERWRITES the server copy unconditionally
/// — the server does NOT order writes by HLC (the previous version of this
/// mock did, which is exactly why the stale-overwrite divergence F21 was
/// invisible to the suite). Monotonic change sequence as the pull cursor.
final class MockSyncServer: SyncTransport {
    private var records: [UUID: (rev: SessionRevision, seq: Int)] = [:]
    private var seq = 0
    private(set) var pushCount = 0

    func push(_ revisions: [SessionRevision]) async throws {
        pushCount += 1
        for rev in revisions {
            guard records[rev.id]?.rev != rev else { continue }   // identical echo: no new change
            seq += 1
            records[rev.id] = (rev, seq)
        }
    }

    /// The server's current copy, for assertions.
    func latest(_ id: UUID) -> SessionRevision? { records[id]?.rev }

    /// How many revisions the server holds, for backlog assertions.
    var recordCount: Int { records.count }

    func pull(since token: SyncToken?) async throws -> (changes: [SessionRevision], token: SyncToken) {
        let after = token.flatMap { Int(String(data: $0.raw, encoding: .utf8) ?? "") } ?? 0
        let changed = records.values.filter { $0.seq > after }
            .sorted { $0.seq < $1.seq }
            .map(\.rev)
        return (changed, SyncToken(raw: Data(String(seq).utf8)))
    }
}

/// Wraps the mock server and fails chosen push calls (1-based sequence) —
/// simulates CloudKit rejecting ONE mid-backlog batch (quota blip, transient
/// server error) while the batches around it are fine.
final class FlakySyncServer: SyncTransport {
    struct BatchRejected: Error {}
    let inner: MockSyncServer
    var failOnPushCalls: Set<Int> = []
    private var pushCalls = 0

    init(_ inner: MockSyncServer) { self.inner = inner }

    func push(_ revisions: [SessionRevision]) async throws {
        pushCalls += 1
        if failOnPushCalls.contains(pushCalls) { throw BatchRejected() }
        try await inner.push(revisions)
    }

    func pull(since token: SyncToken?) async throws -> (changes: [SessionRevision], token: SyncToken) {
        try await inner.pull(since: token)
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

    await c.check("a stale server overwrite is re-asserted — never permanent divergence (F21)") {
        // CloudKit's .allKeys save policy overwrites unconditionally, so two
        // devices' interleaved cycles can land a STALE push after a newer
        // one, reverting the server. The newer device's dirty flag is
        // already cleared by then; without the syncer's re-assertion of a
        // local win, nothing would ever push the newer revision again and
        // the replicas diverge forever. This check simulates the transport-
        // level race and pins the recovery.
        var millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (macStore, macClock, macSync) = device("mac", server: server) { millis }
        let (phoneStore, phoneClock, phoneSync) = device("phone", server: server) { millis }

        let id = UUID()
        let s = Session(id: id, task: .op(1), start: t(0), end: t(600), certainty: 0.9)
        try macStore.saveLocal(SessionRevision(session: s, hlc: macClock.tick(), origin: .auto))
        try await macSync.sync()
        try await phoneSync.sync()

        // Phone edits FIRST (older HLC); mac edits later and completes a
        // clean cycle (pushed, dirty cleared).
        millis += 10
        var phoneEdit = s; phoneEdit.comment = "stale"
        let phoneRev = SessionRevision(session: phoneEdit, hlc: phoneClock.tick(),
                                       origin: .edited)
        millis += 10
        var macEdit = s; macEdit.comment = "newer"
        try macStore.saveLocal(SessionRevision(session: macEdit, hlc: macClock.tick(),
                                               origin: .edited))
        try await macSync.sync()
        try expectEq(server.latest(id)?.session.comment, "newer")

        // The phone's raced cycle: its pull saw nothing newer (it ran before
        // mac's push landed), then its push overwrote the server. Simulate
        // by writing the store as its cycle would and pushing out-of-band.
        try phoneStore.saveLocal(phoneRev)
        try await server.push([phoneRev])
        try phoneStore.clearDirty([phoneRev])
        try expectEq(server.latest(id)?.session.comment, "stale",
                     "the server really was reverted (.allKeys semantics)")

        // One further cycle each: mac re-asserts, phone adopts.
        try await macSync.sync()
        try expectEq(server.latest(id)?.session.comment, "newer",
                     "mac re-pushed the winning revision despite a clean dirty flag")
        try await phoneSync.sync()
        try expectEq(try phoneStore.revision(id: id)?.session.comment, "newer")
        try expectEq(try macStore.allRevisions(), try phoneStore.allRevisions(),
                     "replicas converged after the race")
    }

    await c.check("a large backlog pushes in bounded batches (CloudKit ~400-record cap, F22)") {
        // Enabling sync stamps the WHOLE journal dirty; a single modifyRecords
        // call over a mature journal throws limitExceeded on every retry —
        // sync would never start. The syncer must batch.
        let millis: Int64 = 1_750_000_000_000
        let server = MockSyncServer()
        let (store, clock, syncer) = device("mac", server: server) { millis }
        for i in 0..<450 {
            try store.saveLocal(SessionRevision(
                session: Session(task: .op(1), start: t(Double(i) * 700),
                                 end: t(Double(i) * 700 + 600), certainty: 0.9),
                hlc: clock.tick(), origin: .auto))
        }
        try await syncer.sync()
        try expectEq(server.pushCount, 3, "450 dirty rows → ceil(450/200) batches")
        try expectEq(try store.dirtyRevisionIDs(), [])
        try await syncer.sync()   // echo cycle: nothing re-pushed, no duplicates
        try expectEq(try store.allRevisions().count, 450)
    }

    await c.check("a mid-backlog batch failure keeps only unlanded chunks dirty (criterion 13)") {
        // The failure half of acceptance criterion 13: with per-batch
        // clearDirty, a batch that CloudKit rejects mid-backlog must leave
        // the failed chunk (and the never-attempted tail) dirty for retry —
        // while the chunk that already landed stays CLEAR, so the retry
        // cycle neither re-uploads what the server holds nor loses what it
        // doesn't. A whole-backlog clearDirty (or none) would break one
        // direction or the other; this pins the per-batch semantics.
        let millis: Int64 = 1_750_000_000_000
        let inner = MockSyncServer()
        let flaky = FlakySyncServer(inner)
        let store = InMemoryRevisionStore()
        let clock = HLCClock(deviceID: "mac") { Date(timeIntervalSince1970: Double(millis) / 1000) }
        let syncer = JournalSyncer(store: store, transport: flaky, clock: clock)
        for i in 0..<450 {
            try store.saveLocal(SessionRevision(
                session: Session(task: .op(1), start: t(Double(i) * 700),
                                 end: t(Double(i) * 700 + 600), certainty: 0.9),
                hlc: clock.tick(), origin: .auto))
        }

        // Batch 2 of ceil(450/200)=3 is rejected; the cycle must surface it.
        flaky.failOnPushCalls = [2]
        var threw = false
        do { try await syncer.sync() } catch { threw = true }
        try expect(threw, "a rejected batch must propagate, not be swallowed")
        try expectEq(inner.recordCount, 200, "exactly the first batch landed")
        try expectEq(try store.dirtyRevisionIDs().count, 250,
                     "failed chunk + un-attempted tail stay dirty; the landed 200 are clear")

        // Recovery cycle: only the 250 unlanded rows go up (2 more batches),
        // nothing already on the server is re-pushed, nothing is lost.
        flaky.failOnPushCalls = []
        try await syncer.sync()
        try expectEq(inner.pushCount, 3, "1 landed + 2 retry batches — no re-upload of the cleared chunk")
        try expectEq(inner.recordCount, 450, "the whole backlog reached the server")
        try expectEq(try store.dirtyRevisionIDs(), [])
    }
}

import Foundation
import andeyeTTCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Idempotent push (duplicate-OP-entry root cause)
//
// A successful createTimeEntry followed by a THROWING journal write used to
// leave the session unmarked while OP already held the entry, so the next
// sync re-POSTed it = duplicate. The journal write that gates eligibility is
// now the LEDGER row (setPostingRecord); the fix generalises per row: on a
// ledger-write failure after a successful create, best-effort delete the
// just-created entry before recording the failure, so journal and backend
// stay consistent and the retry re-creates cleanly instead of duplicating.

/// Decorates a real store but throws on the setPostingRecord call(s) we
/// choose, so we can drive the "POST succeeded, journal write failed" window
/// the SQLite store hits when a write throws after a good POST.
final class FailingLedgerJournalStore: JournalStore {
    private let inner: InMemoryJournalStore
    /// setPostingRecord call indices (1-based) that should throw.
    var failOnLedgerCalls: Set<Int>
    private(set) var ledgerCalls = 0

    struct LedgerWriteFailed: Error {}

    init(_ inner: InMemoryJournalStore, failOnLedgerCalls: Set<Int>) {
        self.inner = inner
        self.failOnLedgerCalls = failOnLedgerCalls
    }

    func setPostingRecord(_ record: PostingRecord) throws {
        ledgerCalls += 1
        if failOnLedgerCalls.contains(ledgerCalls) { throw LedgerWriteFailed() }
        try inner.setPostingRecord(record)
    }

    // Everything else is a straight passthrough.
    func save(_ session: Session) throws { try inner.save(session) }
    func allSessions() throws -> [Session] { try inner.allSessions() }
    func session(id: UUID) throws -> Session? { try inner.session(id: id) }
    func sessionCount() throws -> Int { try inner.sessionCount() }
    func pushedCount() throws -> Int { try inner.pushedCount() }
    func sessions(from: Date, to: Date) throws -> [Session] { try inner.sessions(from: from, to: to) }
    func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date] {
        try inner.latestEndByTask(excluding: excluding)
    }
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        try inner.sessions(needingPushAtOrAbove: threshold)
    }
    func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws {
        try inner.markPushed(id, opTimeEntryID: opTimeEntryID)
    }
    func postingRecords(session: UUID) throws -> [PostingRecord] {
        try inner.postingRecords(session: session)
    }
    func postingRecord(session: UUID, backendID: String) throws -> PostingRecord? {
        try inner.postingRecord(session: session, backendID: backendID)
    }
    func clearPostingRecord(session: UUID, backendID: String) throws {
        try inner.clearPostingRecord(session: session, backendID: backendID)
    }
    func sessions(needingPostTo backendID: String, atOrAbove threshold: Double) throws -> [Session] {
        try inner.sessions(needingPostTo: backendID, atOrAbove: threshold)
    }
    func migrateSingleSlotPostings(to backendID: String, excluding: Set<UUID>) throws -> Int {
        try inner.migrateSingleSlotPostings(to: backendID, excluding: excluding)
    }
    func update(_ session: Session) throws { try inner.update(session) }
    func deleteSession(_ id: UUID) throws { try inner.deleteSession(id) }
    func escalateOrigin(_ id: UUID, to origin: SliceOrigin) throws {
        try inner.escalateOrigin(id, to: origin)
    }
    func save(_ segment: ReviewSegment) throws { try inner.save(segment) }
    func pendingReview() throws -> [ReviewSegment] { try inner.pendingReview() }
    func assign(_ segmentIDs: [UUID], to target: Target?) throws { try inner.assign(segmentIDs, to: target) }
    func save(_ span: FocusSpan) throws { try inner.save(span) }
    func spans(from: Date, to: Date) throws -> [FocusSpan] { try inner.spans(from: from, to: to) }
    func saveTaskComment(_ ref: TaskRef, text: String, at date: Date) throws {
        try inner.saveTaskComment(ref, text: text, at: date)
    }
    func taskComments(for ref: TaskRef) throws -> [(date: Date, text: String)] {
        try inner.taskComments(for: ref)
    }
}

func syncIdempotencyChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func makeWorld(failOnLedgerCalls: Set<Int>)
        -> (SyncEngine, FailingLedgerJournalStore, MockTransport) {
        let journal = FailingLedgerJournalStore(InMemoryJournalStore(),
                                                failOnLedgerCalls: failOnLedgerCalls)
        let transport = MockTransport()
        let backend = OPBackend(baseURL: URL(string: "https://op.example.com")!,
                                apiKey: "k", transport: transport)
        return (SyncEngine(journal: journal, backend: backend, id: "op", class: .pm),
                journal, transport)
    }

    await c.check("ledger-write failure after a good POST deletes the OP entry, no duplicate on retry") {
        // 1st setPostingRecord (the posted row) throws; the failure record
        // (2nd call) and the retry's posted row (3rd call) succeed.
        let (engine, journal, transport) = makeWorld(failOnLedgerCalls: [1])
        // create -> id 977, the failure path DELETEs 977, then the retry
        // creates id 978 and records it.
        transport.responses = [(201, #"{"id":977}"#), (204, ""), (201, #"{"id":978}"#)]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))

        // 1st sync: POST 977 succeeds, the ledger write throws -> engine
        // deletes 977 and reports the failure (failure isolation: no throw).
        let first = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(first.first?.posted, 0)
        try expect(first.first?.error != nil, "the ledger-write failure must be reported")

        // Exactly one POST and exactly one DELETE so far.
        let posts1 = transport.requests.filter { $0.httpMethod == "POST" }
        let deletes1 = transport.requests.filter { $0.httpMethod == "DELETE" }
        try expectEq(posts1.count, 1, "exactly one create")
        try expectEq(deletes1.count, 1, "the orphan must be deleted")
        try expect(transport.requests.last!.url!.path.hasSuffix("/time_entries/977"),
                   "the DELETE must target the just-created entry id")
        // Session is still queued (its row is .failed, which retries).
        try expectEq(try journal.sessions(needingPostTo: "op", atOrAbove: 0.8).count, 1,
                     "unmarked session stays queued for a clean retry")

        // 2nd sync: must NOT re-POST the orphan; it creates afresh (978) and marks.
        let second = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(second.first?.posted, 1)
        let postsAll = transport.requests.filter { $0.httpMethod == "POST" }
        try expectEq(postsAll.count, 2,
                     "one create per sync; the failed-then-deleted entry is not double-counted")
        try expectEq(try journal.sessions(needingPostTo: "op", atOrAbove: 0.8).count, 0,
                     "retry records the posted row")
        try expectEq(try journal.allSessions().first?.opTimeEntryID, "978",
                     "journal records the surviving OP entry id")
        try expectEq(((try? journal.postingRecord(
            session: try unwrap(try journal.allSessions().first?.id),
            backendID: "op")) ?? nil)?.entryID, "978")
    }

    await c.check("createTimeEntry surfaces a malformed 2xx body; empty object still returns nil") {
        let transport = MockTransport()
        let client = OPClient(baseURL: URL(string: "https://op.example.com")!,
                              apiKey: "k", transport: transport)
        // Valid-but-id-less body decodes to nil (unchanged behaviour).
        transport.responses = [(201, "{}")]
        let nilID = try await client.createTimeEntry(
            workPackageID: 1, start: t0, duration: 600, activityID: nil, comment: nil)
        try expectNil(nilID, "an empty object is a valid id-less response")
        // A genuinely undecodable 2xx body must now throw rather than orphan silently.
        transport.responses = [(201, "not json")]
        do {
            _ = try await client.createTimeEntry(
                workPackageID: 1, start: t0, duration: 600, activityID: nil, comment: nil)
            throw CheckFailure(description: "malformed 2xx body must throw")
        } catch OPClientError.malformedResponse {
            // expected
        }
    }
}

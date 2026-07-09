import Foundation
import timeandeyeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Idempotent push (duplicate-OP-entry root cause)
//
// A successful createTimeEntry followed by a THROWING journal write used to
// leave the session unmarked while OP already held the entry, so the next
// sync re-POSTed it = duplicate. Two generations of fix:
// (1) the LEDGER row (setPostingRecord) gates eligibility per (session,
//     backend); (2) INTENT-FIRST (F12/D3): the engine writes an `.inflight`
//     row BEFORE the create goes on the wire, so any failure after the
//     create — a throwing posted-row write, or the process dying — leaves
//     evidence instead of amnesia. An `.inflight` row is excluded from
//     eligibility and resolved by verify-then-adopt on a later pass (the
//     adopt/demote flows are pinned with FakeBackend in BillingChecks; here
//     we pin the transport-level guarantees: no create without intent, and
//     no duplicate POST/no rollback DELETE around a failed posted-write).

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
    func postingRecords(state: PostingState, backendID: String) throws -> [PostingRecord] {
        try inner.postingRecords(state: state, backendID: backendID)
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
    func unlockedInvoiceRefs(backendID: String) throws -> Set<String> {
        try inner.unlockedInvoiceRefs(backendID: backendID)
    }
    func addUnlockedInvoiceRef(_ ref: String, backendID: String) throws {
        try inner.addUnlockedInvoiceRef(ref, backendID: backendID)
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

    await c.check("no intent, no create: a failing inflight write blocks the POST entirely") {
        // 1st setPostingRecord is now the INTENT (.inflight) row. If even
        // that can't be written, nothing may go on the wire — a create
        // without recorded intent is exactly the amnesia window F12 closes.
        let (engine, journal, transport) = makeWorld(failOnLedgerCalls: [1])
        transport.responses = [(201, #"{"id":977}"#)]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        let first = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(first.first?.posted, 0)
        try expect(first.first?.error != nil, "the ledger failure must be reported")
        try expectEq(transport.requests.filter { $0.httpMethod == "POST" }.count, 0,
                     "NOTHING went on the wire without intent")
        try expectEq(try journal.sessions(needingPostTo: "op", atOrAbove: 0.8).count, 1,
                     "the session stays cleanly queued")
    }

    await c.check("posted-row failure after a good POST leaves .inflight: no rollback DELETE, no duplicate POST") {
        // Call 1 (the intent row) succeeds; call 2 (the posted row) throws.
        // Old behaviour best-effort DELETEd the fresh entry — which itself
        // could fail and orphan. New behaviour: the row STAYS .inflight,
        // the session is excluded from eligibility, and a later pass's
        // verify-then-adopt resolves it (adopt/demote pinned in
        // BillingChecks with a listable fake).
        let (engine, journal, transport) = makeWorld(failOnLedgerCalls: [2])
        transport.responses = [(201, #"{"id":977}"#)]
        let s = Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                        certainty: 1)
        try journal.save(s)

        let first = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              now: t0.addingTimeInterval(700))
        try expectEq(first.first?.posted, 0)
        try expect(first.first?.error != nil)
        try expectEq(transport.requests.filter { $0.httpMethod == "POST" }.count, 1,
                     "exactly one create")
        try expectEq(transport.requests.filter { $0.httpMethod == "DELETE" }.count, 0,
                     "the fresh entry is NOT deleted — intent survives for adopt")
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "op")) ?? nil)?.state,
                     .inflight, "the intent row is the evidence")
        try expectEq(try journal.sessions(needingPostTo: "op", atOrAbove: 0.8).count, 0,
                     "an unresolved inflight session is NOT eligible")

        // A pass INSIDE the settle floor must not touch it: no blind create,
        // no premature verify (the backend's list index may lag).
        let second = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               now: t0.addingTimeInterval(730))
        try expectEq(second.first?.posted, 0)
        try expectEq(transport.requests.filter { $0.httpMethod == "POST" }.count, 1,
                     "still exactly one create — never a duplicate")
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "op")) ?? nil)?.state,
                     .inflight)
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

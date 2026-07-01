import Foundation
import AmbitickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Idempotent push (duplicate-OP-entry root cause)
//
// A successful createTimeEntry followed by a THROWING markPushed used to leave
// the session pushedToOP=false while OP already held the entry, so the next
// sync re-POSTed it = duplicate. The fix: on a markPushed failure after a
// successful create, best-effort delete the just-created OP entry before
// rethrowing, so journal and OP stay consistent and the retry re-creates
// cleanly instead of duplicating.

/// Decorates a real store but throws on the markPushed call(s) we choose,
/// so we can drive the "POST succeeded, journal save failed" window the
/// SQLite store hits when save() throws after a good POST.
final class FailingMarkJournalStore: JournalStore {
    private let inner: InMemoryJournalStore
    /// markPushed call indices (1-based) that should throw instead of marking.
    var failOnMarkCalls: Set<Int>
    private(set) var markCalls = 0

    struct MarkFailed: Error {}

    init(_ inner: InMemoryJournalStore, failOnMarkCalls: Set<Int>) {
        self.inner = inner
        self.failOnMarkCalls = failOnMarkCalls
    }

    func markPushed(_ id: UUID, opTimeEntryID: Int?) throws {
        markCalls += 1
        if failOnMarkCalls.contains(markCalls) { throw MarkFailed() }
        try inner.markPushed(id, opTimeEntryID: opTimeEntryID)
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
    func update(_ session: Session) throws { try inner.update(session) }
    func deleteSession(_ id: UUID) throws { try inner.deleteSession(id) }
    func save(_ segment: ReviewSegment) throws { try inner.save(segment) }
    func pendingReview() throws -> [ReviewSegment] { try inner.pendingReview() }
    func assign(_ segmentIDs: [UUID], to target: Target?) throws { try inner.assign(segmentIDs, to: target) }
    func save(_ span: FocusSpan) throws { try inner.save(span) }
    func spans(from: Date, to: Date) throws -> [FocusSpan] { try inner.spans(from: from, to: to) }
}

func syncIdempotencyChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func makeWorld(failOnMarkCalls: Set<Int>)
        -> (SyncEngine, FailingMarkJournalStore, MockTransport) {
        let journal = FailingMarkJournalStore(InMemoryJournalStore(),
                                              failOnMarkCalls: failOnMarkCalls)
        let transport = MockTransport()
        let backend = OPBackend(baseURL: URL(string: "https://op.example.com")!,
                                apiKey: "k", transport: transport)
        return (SyncEngine(journal: journal, backend: backend), journal, transport)
    }

    await c.check("markPushed failure after a good POST deletes the OP entry, no duplicate on retry") {
        // First markPushed throws; the retry's markPushed succeeds.
        let (engine, journal, transport) = makeWorld(failOnMarkCalls: [1])
        // create -> id 977, the failure path DELETEs 977, then the retry
        // creates id 978 and marks it.
        transport.responses = [(201, #"{"id":977}"#), (204, ""), (201, #"{"id":978}"#)]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))

        // 1st sync: POST 977 succeeds, markPushed throws -> engine deletes 977 and rethrows.
        var caught: Error?
        do { _ = try await engine.pushEligible(threshold: 0.8, includeComments: false) }
        catch { caught = error }
        try expect(caught != nil, "markPushed failure must propagate")

        // Exactly one POST and exactly one DELETE so far.
        let posts1 = transport.requests.filter { $0.httpMethod == "POST" }
        let deletes1 = transport.requests.filter { $0.httpMethod == "DELETE" }
        try expectEq(posts1.count, 1, "exactly one create")
        try expectEq(deletes1.count, 1, "the orphan must be deleted")
        try expect(transport.requests.last!.url!.path.hasSuffix("/time_entries/977"),
                   "the DELETE must target the just-created entry id")
        // Session is still queued (markPushed failed) so the next sync retries.
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8).count, 1,
                     "unmarked session stays queued for a clean retry")

        // 2nd sync: must NOT re-POST the orphan; it creates afresh (978) and marks.
        let pushed = try await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pushed, 1)
        let postsAll = transport.requests.filter { $0.httpMethod == "POST" }
        try expectEq(postsAll.count, 2,
                     "one create per sync; the failed-then-deleted entry is not double-counted")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8).count, 0,
                     "retry marks the session pushed")
        try expectEq(try journal.allSessions().first?.opTimeEntryID, 978,
                     "journal records the surviving OP entry id")
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

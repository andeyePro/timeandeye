import Foundation
import AmbitickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - JournalStore conformance (plan task 9)
// Run against any implementation; the GRDB store in the app target reuses this.

func journalStoreConformanceChecks(_ c: Checks, make: () -> any JournalStore) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func session(_ certainty: Double, task: TaskRef = .op(1), pushed: Bool = false) -> Session {
        Session(task: task, start: t0, end: t0.addingTimeInterval(600),
                certainty: certainty, pushedToOP: pushed)
    }

    c.check("saves and lists sessions") {
        let s = make()
        let a = session(0.9)
        try s.save(a)
        try expectEq(try s.allSessions(), [a])
    }

    c.check("session(id:) fetches one row; miss returns nil") {
        let s = make()
        let a = session(0.9)
        let b = session(0.7, task: .op(2))
        try s.save(a)
        try s.save(b)
        try expectEq(try s.session(id: a.id), a)
        try expectEq(try s.session(id: b.id), b)
        try expectNil(try s.session(id: UUID()), "unknown id is nil, not a throw")
    }

    c.check("sessionCount / pushedCount") {
        let s = make()
        try s.save(session(0.9))                       // unpushed
        try s.save(session(0.95, pushed: true))        // pushed
        try s.save(session(0.8, task: .op(2), pushed: true))   // pushed
        try expectEq(try s.sessionCount(), 3)
        try expectEq(try s.pushedCount(), 2)
    }

    c.check("push eligibility filters by threshold, pushed and local-only") {
        let s = make()
        let eligible = session(0.9)
        try s.save(eligible)
        try s.save(session(0.5))                                  // below threshold
        try s.save(session(0.95, pushed: true))                   // already pushed
        try s.save(session(0.99, task: .local(UUID())))           // local-only: never pushed
        try expectEq(try s.sessions(needingPushAtOrAbove: 0.8), [eligible])
        try expectEq(try s.sessions(needingPushAtOrAbove: 1.01), [])   // the "101%" setting
    }

    c.check(".remote sessions are push-eligible; latestEndByTask keys them") {
        let s = make()
        let xero = session(0.9, task: .remote("guid-1"))
        try s.save(xero)
        try s.save(session(0.99, task: .local(UUID())))
        try expectEq(try s.sessions(needingPushAtOrAbove: 0.8), [xero])
        try expectEq(try s.latestEndByTask(excluding: [])[.remote("guid-1")], xero.end)
    }

    c.check("mark pushed records the backend entry id") {
        let s = make()
        let a = session(0.9)
        try s.save(a)
        try s.markPushed(a.id, opTimeEntryID: "977")
        try expectEq(try s.sessions(needingPushAtOrAbove: 0.8), [])
        try expectEq(try s.allSessions().first?.pushedToOP, true)
        try expectEq(try s.allSessions().first?.opTimeEntryID, "977")
    }

    c.check("legacy journal rows with an Int entry id decode to the widened String") {
        let json = """
        {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","task":{"op":{"_0":42}},
         "start":1750000000,"end":1750000600,"certainty":0.9,
         "pushedToOP":true,"opTimeEntryID":977}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let s = try decoder.decode(Session.self, from: Data(json.utf8))
        try expectEq(s.opTimeEntryID, "977", "pre-widening Int id survives")
        // And the widened form round-trips.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let re = try decoder.decode(Session.self, from: encoder.encode(s))
        try expectEq(re, s)
    }

    c.check("update, delete, day query") {
        let s = make()
        var a = session(0.9)
        let b = session(0.7, task: .op(2))
        try s.save(a)
        try s.save(b)
        a.end = a.end.addingTimeInterval(600)
        a.comment = "edited"
        try s.update(a)
        try expectEq(try s.allSessions().first { $0.id == a.id }?.comment, "edited")
        try s.deleteSession(b.id)
        try expectEq(try s.allSessions().count, 1)
        let day = try s.sessions(from: t0.addingTimeInterval(-3600),
                                 to: t0.addingTimeInterval(3600))
        try expectEq(day.map(\.id), [a.id])
        try expectEq(try s.sessions(from: t0.addingTimeInterval(90_000),
                                    to: t0.addingTimeInterval(100_000)).count, 0)
    }

    c.check("latestEndByTask aggregates per task and honours exclusions") {
        let s = make()
        let a = session(0.9)                                        // op(1), t0..t0+600
        let later = Session(task: .op(1), start: t0.addingTimeInterval(1000),
                            end: t0.addingTimeInterval(1600), certainty: 0.9)
        let other = session(0.7, task: .op(2))
        let checkpoint = Session(task: .op(1), start: t0.addingTimeInterval(9000),
                                 end: t0.addingTimeInterval(9600), certainty: 0.9)
        try s.save(a)
        try s.save(later)
        try s.save(other)
        try s.save(checkpoint)
        let all = try s.latestEndByTask(excluding: [])
        try expectEq(all[.op(1)], checkpoint.end)
        try expectEq(all[.op(2)], other.end)
        // Excluding the live-checkpoint row must fall back to the real slices.
        let real = try s.latestEndByTask(excluding: [checkpoint.id])
        try expectEq(real[.op(1)], later.end)
        try expectEq(real.count, 2)
    }

    c.check("spans round-trip with range query") {
        let s = make()
        let signal = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: t0)
        let span = FocusSpan(target: .task(.op(1)), certainty: 0.95, signal: signal,
                             start: t0, end: t0.addingTimeInterval(120))
        try s.save(span)
        let hits = try s.spans(from: t0.addingTimeInterval(-10), to: t0.addingTimeInterval(10))
        try expectEq(hits.count, 1)
        try expectEq(hits.first?.signal.windowTitle, "Ambitick")
        try expectEq(try s.spans(from: t0.addingTimeInterval(500),
                                 to: t0.addingTimeInterval(600)).count, 0)
    }

    c.check("review segment assignment") {
        let s = make()
        let seg1 = ReviewSegment(app: "Mystery", start: t0, end: t0.addingTimeInterval(60))
        let seg2 = ReviewSegment(app: "Other", start: t0, end: t0.addingTimeInterval(120))
        try s.save(seg1)
        try s.save(seg2)
        try expectEq(try s.pendingReview().count, 2)
        try s.assign([seg1.id], to: .task(.op(7)))
        try expectEq(try s.pendingReview().map(\.id), [seg2.id])
    }
}

func inMemoryJournalChecks(_ c: Checks) {
    journalStoreConformanceChecks(c) { InMemoryJournalStore() }
}

// MARK: - Mock transport for OPClient/SyncEngine/E2E checks

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    /// Queue of (status, body) responses, consumed in order.
    var responses: [(Int, String)] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.isEmpty ? (200, "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

// MARK: - OPClient (plan task 10)

func opClientChecks(_ c: Checks) async {
    func makeClient(_ transport: MockTransport) -> OPClient {
        OPClient(baseURL: URL(string: "https://op.example.com")!,
                 apiKey: "SECRET", transport: transport)
    }

    await c.check("fetchTasks pages through and parses") {
        let transport = MockTransport()
        transport.responses = [
            (200, """
            {"total": 3, "count": 2, "_embedded": {"elements": [
              {"id": 1, "subject": "Ambitick build",
               "_links": {"status": {"title": "Now"}, "project": {"title": "Ambitick"}}},
              {"id": 2, "subject": "Timesheets",
               "_links": {"status": {"title": "Closed"}, "project": {"title": "Admin"}}}
            ]}}
            """),
            (200, """
            {"total": 3, "count": 1, "_embedded": {"elements": [
              {"id": 3, "subject": "Investment review",
               "_links": {"status": {"title": "Next"}, "project": {"title": "Investment"}}}
            ]}}
            """),
        ]
        let tasks = try await makeClient(transport).fetchTasks(pageSize: 2)
        try expectEq(tasks.count, 3)
        try expectEq(tasks[0], WorkTask(ref: .op(1), subject: "Ambitick build",
                                        project: "Ambitick", status: "Now"))
        try expectEq(transport.requests.count, 2)
        try expectEq(transport.requests[0].value(forHTTPHeaderField: "Authorization"),
                     "Basic " + Data("apikey:SECRET".utf8).base64EncodedString())
        try expect(transport.requests[1].url!.absoluteString.contains("offset=2"),
                   "second page must use page number 2")
    }

    await c.check("fetchActivities via time-entry form") {
        let transport = MockTransport()
        transport.responses = [(200, """
        {"_embedded": {"schema": {"activity": {"_embedded": {"allowedValues": [
            {"id": 4, "name": "Development"}, {"id": 5, "name": "Management"}
        ]}}}}}
        """)]
        let activities = try await makeClient(transport).fetchActivities()
        try expectEq(activities, [OPTimeActivity(id: 4, name: "Development"),
                                  OPTimeActivity(id: 5, name: "Management")])
        try expectEq(transport.requests[0].httpMethod, "POST")
        try expect(transport.requests[0].url!.path.hasSuffix("/api/v3/time_entries/form"))
    }

    await c.check("listTimeEntries parses id, work package, duration and comment") {
        let transport = MockTransport()
        transport.responses = [(200, """
        {"total": 2, "count": 2, "_embedded": {"elements": [
          {"id": 11, "hours": "PT1H30M", "spentOn": "2026-06-20", "startTime": "09:15",
           "comment": {"raw": "work"}, "createdAt": "2026-06-20T09:16:00Z",
           "_links": {"workPackage": {"href": "/api/v3/work_packages/42"},
                      "activity": {"title": "Development"}}},
          {"id": 12, "hours": "PT0H45M", "spentOn": "2026-06-20", "startTime": "09:15",
           "comment": {"raw": null}, "_links": {"workPackage": {"href": "/api/v3/work_packages/42"}}}
        ]}}
        """)]
        let entries = try await makeClient(transport)
            .listTimeEntries(from: Date(timeIntervalSince1970: 1_750_000_000),
                             to: Date(timeIntervalSince1970: 1_760_000_000))
        try expectEq(entries.count, 2)
        try expectEq(entries[0].id, 11)
        try expectEq(entries[0].workPackageID, 42)
        try expectEq(entries[0].durationSeconds, 5400)
        try expectEq(entries[0].comment, "work")
        try expectEq(entries[0].activity, "Development")
        try expect(entries[0].createdAt != nil, "createdAt parsed")
        try expectNil(entries[1].comment)
        try expect(transport.requests[0].url!.path.hasSuffix("/api/v3/time_entries"))
    }

    await c.check("createTimeEntry body") {
        let transport = MockTransport()
        transport.responses = [(201, "{}")]
        let start = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15 UTC
        try await makeClient(transport).createTimeEntry(
            workPackageID: 42, start: start, duration: 5_400,
            activityID: 4, comment: "Ghostty – Ambitick")
        let body = try unwrap(transport.requests[0].httpBody)
        let json = try unwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        try expectEq(json["hours"] as? String, "PT1H30M")
        try expectEq(json["spentOn"] as? String, "2025-06-15")
        let links = try unwrap(json["_links"] as? [String: [String: String]])
        try expectEq(links["workPackage"]?["href"], "/api/v3/work_packages/42")
        try expectEq(links["activity"]?["href"], "/api/v3/time_entries/activities/4")
        try expectEq((json["comment"] as? [String: String])?["raw"], "Ghostty – Ambitick")
        try expectNil(json["startTime"], "omitted unless requested")
    }

    await c.check("createTimeEntry returns the new id; update PATCHes; delete DELETEs") {
        let transport = MockTransport()
        transport.responses = [(201, #"{"_type":"TimeEntry","id":977}"#), (200, "{}"), (204, "")]
        let client = makeClient(transport)
        let id = try await client.createTimeEntry(
            workPackageID: 42, start: Date(timeIntervalSince1970: 1_750_000_000),
            duration: 600, activityID: nil, comment: nil)
        try expectEq(id, 977)
        try await client.updateTimeEntry(id: 977, workPackageID: 42,
                                         start: Date(timeIntervalSince1970: 1_750_000_000),
                                         duration: 1200, activityID: nil, comment: "edited")
        try expectEq(transport.requests[1].httpMethod, "PATCH")
        try expect(transport.requests[1].url!.path.hasSuffix("/time_entries/977"))
        try await client.deleteTimeEntry(id: 977)
        try expectEq(transport.requests[2].httpMethod, "DELETE")
    }

    await c.check("createTimeEntry carries startTime when given") {
        let transport = MockTransport()
        transport.responses = [(201, "{}")]
        try await makeClient(transport).createTimeEntry(
            workPackageID: 42, start: Date(timeIntervalSince1970: 1_750_000_000),
            duration: 600, activityID: nil, comment: nil, startTime: "09:30")
        let json = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        try expectEq(json["startTime"] as? String, "09:30")
    }

    await c.check("fetchMe returns the key's user") {
        let transport = MockTransport()
        transport.responses = [(200, #"{"id": 4, "name": "Martin Currie"}"#)]
        let name = try await makeClient(transport).fetchMe()
        try expectEq(name, "Martin Currie")
        try expect(transport.requests[0].url!.path.hasSuffix("/api/v3/users/me"))
    }

    await c.check("non-2xx throws") {
        let transport = MockTransport()
        transport.responses = [(401, #"{"message": "no"}"#)]
        do {
            _ = try await makeClient(transport).fetchTasks()
            throw CheckFailure(description: "expected throw")
        } catch let OPClientError.httpStatus(code, _) {
            try expectEq(code, 401)
        }
    }
}

// MARK: - SyncEngine (plan task 11)

func syncEngineChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func makeWorld() -> (SyncEngine, InMemoryJournalStore, MockTransport) {
        let journal = InMemoryJournalStore()
        let transport = MockTransport()
        let backend = OPBackend(baseURL: URL(string: "https://op.example.com")!,
                                apiKey: "k", transport: transport)
        return (SyncEngine(journal: journal, backend: backend), journal, transport)
    }

    await c.check("pushes eligible and marks") {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(1800),
                                 certainty: 0.9, comment: "Ghostty – Ambitick"))
        try journal.save(Session(task: .op(43), start: t0, end: t0.addingTimeInterval(60),
                                 certainty: 0.4))   // below threshold: stays local
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: true)
        try expectEq(pushed, 1)
        try expectEq(transport.requests.count, 1)
        let body = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        try expectEq(body["hours"] as? String, "PT0H30M")
        try expectEq((body["comment"] as? [String: String])?["raw"], "Ghostty – Ambitick")
        try expectEq(body["startTime"] as? String, "2025-06-15T15:06:40Z",
                     "ISO 8601 UTC date-time, not HH:mm")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8), [])
    }

    await c.check("activity override per task; comments excludable") {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1, comment: "should not appear"))
        _ = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                          activityOverrides: [.op(42): 9],
                                          includeComments: false)
        let body = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        let links = try unwrap(body["_links"] as? [String: [String: String]])
        try expectEq(links["activity"]?["href"], "/api/v3/time_entries/activities/9")
        try expectNil(body["comment"])
    }

    await c.check("no default activity: POST goes out without an activity link") {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        let pushed = try await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pushed, 1)
        let body = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        let links = try unwrap(body["_links"] as? [String: [String: String]])
        try expectNil(links["activity"], "activity link must be omitted when nil")
        try expectEq(links["workPackage"]?["href"], "/api/v3/work_packages/42")
    }

    await c.check("422 on startTime falls back to plain entries") {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(422, #"{"message": "startTime disabled"}"#), (201, "{}"),
                               (201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        try journal.save(Session(task: .op(43), start: t0.addingTimeInterval(700),
                                 end: t0.addingTimeInterval(1400), certainty: 1))
        let pushed = try await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pushed, 2)
        try expectEq(transport.requests.count, 3, "one retry, then no more startTime attempts")
        let retryBody = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[1].httpBody)) as? [String: Any])
        try expectNil(retryBody["startTime"])
        let secondEntry = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[2].httpBody)) as? [String: Any])
        try expectNil(secondEntry["startTime"])
    }

    await c.check("sub-minute sessions are cleared without a POST") {
        let (engine, journal, transport) = makeWorld()
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(30),
                                 certainty: 1))
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: false)
        try expectEq(pushed, 0)
        try expectEq(transport.requests.count, 0, "no zero-duration entries in OP")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8), [],
                     "short sessions must not clog the queue")
    }

    await c.check("failed push leaves session unmarked") {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(500, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        let pushed = try? await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                    includeComments: false)
        try expect(pushed != 1, "push must not report success")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8).count, 1,
                     "failed push must remain queued")
    }
}

// MARK: - SyncEngine × GUID backends (TaskRef.remote migration)

/// Minimal GUID-keyed backend: owns .remote only, records what it's asked to
/// create — the shape the Xero conformer takes.
final class StubGUIDBackend: TaskBackend {
    var created: [(taskID: String, comment: String?)] = []
    var displayName: String { "Stub" }
    var pageRecognizer: BackendPageRecognizer { NoPageRecognizer() }
    var supportsActivities: Bool { false }
    var supportsTaskComments: Bool { false }
    func owns(_ ref: TaskRef) -> Bool {
        if case .remote = ref { return true }
        return false
    }
    func fetchTasks() async throws -> [WorkTask] { [] }
    func fetchMe() async throws -> String { "" }
    func fetchActivities() async throws -> [TimeActivity] { [] }
    func taskURL(id: String) -> URL? { nil }
    func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                         activityID: Int?, comment: String?) async throws -> RemoteEntryID? {
        created.append((taskID, comment))
        return "entry-guid-\(created.count)"
    }
    func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                         duration: TimeInterval, activityID: Int?, comment: String?) async throws {}
    func updateEntryComment(id: RemoteEntryID, comment: String) async throws {}
    func deleteTimeEntry(id: RemoteEntryID) async throws {}
    func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry] { [] }
    func addTaskComment(taskID: String, text: String) async throws {}
}

func syncEngineOwnershipChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    await c.check("a .remote session pushes to its GUID backend and marks with the GUID entry id") {
        let journal = InMemoryJournalStore()
        let backend = StubGUIDBackend()
        try journal.save(Session(task: .remote("task-guid-9"), start: t0,
                                 end: t0.addingTimeInterval(1800), certainty: 0.95))
        let pushed = try await SyncEngine(journal: journal, backend: backend)
            .pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pushed, 1)
        try expectEq(backend.created.first?.taskID, "task-guid-9",
                     "the GUID travels verbatim")
        try expectEq(try journal.allSessions().first?.opTimeEntryID, "entry-guid-1")
    }

    await c.check("ownership guard: an eligible .op session is SKIPPED by a GUID backend — not pushed, not marked") {
        let journal = InMemoryJournalStore()
        let backend = StubGUIDBackend()
        try journal.save(Session(task: .op(42), start: t0,
                                 end: t0.addingTimeInterval(1800), certainty: 0.95))
        let pushed = try await SyncEngine(journal: journal, backend: backend)
            .pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pushed, 0)
        try expectEq(backend.created.count, 0)
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8).count, 1,
                     "stays queued for ITS backend — never silently marked")
    }
}

// MARK: - AIAssist (plan task 12)

func aiAssistChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let segID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let tasks = [WorkTask(ref: .op(1), subject: "Ambitick build",
                          project: "Ambitick", status: "Now")]
    let segments = [ReviewSegment(id: segID, app: "Chrome", windowTitle: "Spreadsheet xyz",
                                  start: t0, end: t0.addingTimeInterval(300))]

    c.check("prompt contains tasks, segments and format contract") {
        let prompt = AIAssist.classificationPrompt(tasks: tasks, segments: segments)
        try expect(prompt.contains("Ambitick build"))
        try expect(prompt.contains("#1"))
        try expect(prompt.contains(segID.uuidString))
        try expect(prompt.contains("Spreadsheet xyz"))
        try expect(prompt.contains(#""assignments""#))
        try expect(prompt.contains("do-not-track"))
    }

    // The id→ref lookup parseResponse resolves through (built from the task
    // cache in production; ids the model invents are skipped, not fabricated).
    let lookup: [String: TaskRef] = ["1": .op(1), "2": .op(2),
                                     "g-42": .remote("g-42")]

    c.check("parses valid response — int, GUID string, and do-not-track") {
        let json = """
        {"assignments": [
          {"segment": "\(segID.uuidString)", "task": 1},
          {"segment": "\(segID.uuidString)", "task": "g-42"},
          {"segment": "\(segID.uuidString)", "task": "do-not-track"}
        ]}
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID],
                                                taskRefByID: lookup)
        try expectEq(parsed, [
            AIAssist.Assignment(segmentID: segID, target: .task(.op(1))),
            AIAssist.Assignment(segmentID: segID, target: .task(.remote("g-42"))),
            AIAssist.Assignment(segmentID: segID, target: .doNotTrack),
        ])
    }

    c.check("skips unknown segments AND unknown task ids, rejects garbage") {
        // A stray/hallucinated uuid must NOT throw away the whole batch — it is
        // skipped and the matching assignments still apply.
        let mixed = try AIAssist.parseResponse(
            #"{"assignments": [{"segment": "\#(UUID().uuidString)", "task": 1}, {"segment": "\#(segID.uuidString)", "task": 2}]}"#,
            validSegmentIDs: [segID], taskRefByID: lookup)
        try expectEq(mixed, [AIAssist.Assignment(segmentID: segID, target: .task(.op(2)))])
        // A hallucinated TASK id is skipped too — the old blind .op(n) mapping
        // could fabricate a nonexistent work package.
        let ghost = try AIAssist.parseResponse(
            #"{"assignments": [{"segment": "\#(segID.uuidString)", "task": 999}]}"#,
            validSegmentIDs: [segID], taskRefByID: lookup)
        try expectEq(ghost, [])
        try expectThrows("non-JSON must throw") {
            _ = try AIAssist.parseResponse("not json", validSegmentIDs: [segID],
                                           taskRefByID: lookup)
        }
        try expectThrows("boolean task must throw") {
            _ = try AIAssist.parseResponse(
                #"{"assignments": [{"segment": "\#(segID.uuidString)", "task": true}]}"#,
                validSegmentIDs: [segID], taskRefByID: lookup)
        }
    }

    c.check("tolerates code-fence wrapping") {
        let json = """
        ```json
        {"assignments": [{"segment": "\(segID.uuidString)", "task": 1}]}
        ```
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID],
                                                taskRefByID: lookup)
        try expectEq(parsed.count, 1)
    }

    c.check("classificationPrompt lists remote GUID tasks; taskRefLookup round-trips") {
        let mixed = tasks + [WorkTask(ref: .remote("guid-7"), subject: "Xero job",
                                      project: "Client", status: "ACTIVE"),
                             WorkTask(ref: .local(UUID()), subject: "Chess", status: "Leisure")]
        let prompt = AIAssist.classificationPrompt(tasks: mixed, segments: segments)
        try expect(prompt.contains("#guid-7: Xero job"), "GUID tasks listed")
        try expect(!prompt.contains("Chess"), ".local stays out of AI scope")
        let built = AIAssist.taskRefLookup(mixed)
        try expectEq(built["guid-7"], .remote("guid-7"))
        try expectEq(built["1"], .op(1))
        try expectEq(built.count, 2, ".local contributes no key")
    }

    c.check("pin-rule prompt carries the surface fields, grammar and advice") {
        let prompt = AIAssist.pinRulePrompt(app: "Ghostty", title: "voting – nvim",
                                            url: nil, advice: "key on the app")
        try expect(prompt.contains("Ghostty"))
        try expect(prompt.contains("voting – nvim"))
        try expect(prompt.contains("(none)"), "nil url renders as (none)")
        try expect(prompt.contains("contains"))
        try expect(prompt.contains("matches"))
        try expect(prompt.contains("key on the app"), "advice is included")
    }

    c.check("pin-rule reply cleaner strips fences and trailing prose") {
        try expectEq(AIAssist.cleanRuleReply("```\napp is \"Ghostty\"\n```"),
                     "app is \"Ghostty\"")
        // Models sometimes add a note on a second line — keep only the rule.
        try expectEq(AIAssist.cleanRuleReply("url contains \"op\"\nThis matches…"),
                     "url contains \"op\"")
        try expectEq(AIAssist.cleanRuleReply("  title is \"X\"  "), "title is \"X\"")
    }

    c.check("email-address extraction: distinct, ordered, case-insensitive dedupe") {
        let blob = """
        Re: Emergency flea — from Taylor <taylor@fermentory.example>
        to martin@andeye.com, MARTIN@andeye.com; cc a.b+tag@sub.example.co.uk
        not-an-email @ nope, plain text, https://mail.google.com/#x
        """
        try expectEq(EmailSignal.addresses(in: blob),
                     ["taylor@fermentory.example", "martin@andeye.com", "a.b+tag@sub.example.co.uk"])
        try expectEq(EmailSignal.addresses(in: "no addresses here"), [])
    }

    c.check("email system detection from host") {
        try expectEq(EmailSystem.detect(urlHost: "mail.google.com"), .gmail)
        try expectEq(EmailSystem.detect(urlHost: "outlook.office.com"), .outlookWeb)
        try expectEq(EmailSystem.detect(urlHost: "mail.proton.me"), .proton)
        try expectEq(EmailSystem.detect(urlHost: "example.com"), .unknown)
        try expectEq(EmailSystem.detect(urlHost: nil), .unknown)
        try expect(EmailSystem.gmail.senderSelector == ".gD")
        try expect(EmailSystem.gmail.recipientSelector == ".g2")
        try expect(!EmailSystem.outlookWeb.hasRecipe, "no recipe yet for OWA")
    }

    c.check("counterparties drop self ('me', own addr/domain), keep the other party") {
        // The validated Insurance-Renewals shape: sender Rae, recipients me + Tess.
        let senders = [EmailSignal.Party(name: "Rae Naismith", email: "r.naismith@harborlane.example")]
        let recips = [EmailSignal.Party(name: "me", email: "martin@andeye.com"),
                      EmailSignal.Party(name: "Tess", email: "t.calder@harborlane.example")]
        let others = EmailSignal.counterparties(senders: senders, recipients: recips)
        try expectEq(others.map(\.email),
                     ["r.naismith@harborlane.example", "t.calder@harborlane.example"])
        // Own-domain removal also works when you sent the last reply (sender = you).
        let mine = EmailSignal.counterparties(
            senders: [EmailSignal.Party(name: "Martin", email: "martin@andeye.com")],
            recipients: [EmailSignal.Party(name: "Rae", email: "r.naismith@harborlane.example")],
            ownDomains: ["andeye.com"])
        try expectEq(mine.map(\.email), ["r.naismith@harborlane.example"])
        try expectEq(EmailSignal.domain(of: "r.naismith@harborlane.example"), "harborlane.example")
        // Subject from a Gmail tab title (strips the " - account - Mail" tail).
        try expectEq(EmailSignal.subject(fromTitle:
            "RE: Insurance Renewals - martin@andeye.com - andeye Mail"), "RE: Insurance Renewals")
        try expectNil(EmailSignal.subject(fromTitle: nil))
        try expectEq(EmailSignal.subject(fromTitle: "No dashes here"), "No dashes here")
    }

    c.check("email match ladder: most-specific level wins, user order re-tunes") {
        let ctx = EmailContext(system: .gmail,
                               correspondents: ["r.naismith@harborlane.example",
                                                "t.calder@harborlane.example"],
                               subject: "RE: Insurance Renewals")
        let domainRule = EmailRule(level: .correspondentDomain, value: "harborlane.example", target: .op(1))
        let subjRule = EmailRule(level: .subject, value: "Insurance Renewals", target: .op(2))
        let sysRule = EmailRule(level: .emailSystem, value: "", target: .op(9))
        // Subject (most specific) beats domain beats system, by default.
        try expectEq(EmailMatcher.match(ctx, rules: [sysRule, domainRule, subjRule])?.target, .op(2))
        try expectEq(EmailMatcher.match(ctx, rules: [sysRule, domainRule])?.target, .op(1))
        try expectEq(EmailMatcher.match(ctx, rules: [sysRule])?.target, .op(9))
        try expectNil(EmailMatcher.match(ctx, rules: []))
        // A pin beats a learned rule at the SAME level.
        let learnedDom = EmailRule(level: .correspondentDomain, value: "harborlane.example", target: .op(1))
        let pinnedDom = EmailRule(level: .correspondentDomain, value: "harborlane.example", target: .op(5), pinned: true)
        try expectEq(EmailMatcher.match(ctx, rules: [learnedDom, pinnedDom])?.target, .op(5))
        // Re-tuning the order (correspondent above subject) flips precedence.
        let cpRule = EmailRule(level: .correspondent, value: "r.naismith@harborlane.example", target: .op(7))
        let custom: [EmailMatchLevel] = [.emailSystem, .correspondentDomain, .subject, .correspondent]
        try expectEq(EmailMatcher.match(ctx, rules: [subjRule, cpRule], order: custom)?.target, .op(7))
        // Subject matches by substring (handles RE:/Fwd: prefixes); non-match → nil.
        try expectNil(EmailMatcher.match(ctx, rules: [EmailRule(level: .subject, value: "Payroll", target: .op(3))]))
    }

    c.check("correspondent matching is direction-agnostic (sent vs received)") {
        // Same company (Rae), whether he's the sender (inbound) or a recipient
        // of a mail you sent (outbound) — one domain rule covers both.
        let rule = EmailRule(level: .correspondentDomain, value: "harborlane.example", target: .op(1))
        let inbound = EmailContext(system: .gmail, correspondents: ["r.naismith@harborlane.example"],
                                   subject: "Quote")
        let outbound = EmailContext(system: .gmail, correspondents: ["t.calder@harborlane.example"],
                                    subject: "Re: Quote")
        try expectEq(EmailMatcher.match(inbound, rules: [rule])?.target, .op(1))
        try expectEq(EmailMatcher.match(outbound, rules: [rule])?.target, .op(1))
        try expectEq(inbound.correspondentDomains, ["harborlane.example"])
    }
}

// MARK: - Settings (plan task 13)

func settingsChecks(_ c: Checks) {
    c.check("JSONFileStore backs up each save and recovers the latest value from a corrupt main") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let store = JSONFileStore<AmbitickSettings>(url: url)
        try store.save(AmbitickSettings(opBaseURL: "https://op.example.com"))
        try store.save(AmbitickSettings(opBaseURL: "https://op2.example.com"))  // bak mirrors latest
        try Data("{ not valid json".utf8).write(to: url)                        // corrupt the main
        try expectEq(try store.load()?.opBaseURL, "https://op2.example.com",
                     "recovers the LATEST value from .bak instead of throwing")
        try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
                   "the corrupt file is preserved, not silently lost")
        // A save after corruption restores a good main + bak again.
        try store.save(AmbitickSettings(opBaseURL: "https://op3.example.com"))
        try expectEq(try store.load()?.opBaseURL, "https://op3.example.com")
    }

    c.check("unknown/renamed enum values must NOT wipe the settings file (keeps the OP URL)") {
        // Regression: a settings.json written by an older build can carry enum
        // rawValues that a later build renamed (here emailMatchOrder's old
        // "senderDomain"/"sender", and a bogus timeViewOpenMode). Decoding must
        // survive, preserve opBaseURL, and fall back to defaults for the bad enums
        // — NOT throw and lose the whole file (which logs the user out of OP).
        // Includes a renamed enum (emailMatchOrder/timeViewOpenMode) AND a
        // type-mismatched field (menuTaskChars as a string) — every one must drop
        // to its default WITHOUT failing the whole file.
        let json = """
        {"opBaseURL":"https://op.example.com",
         "emailMatchOrder":["emailSystem","senderDomain","sender","subject"],
         "timeViewOpenMode":"someFutureMode",
         "menuTaskChars":"not-a-number",
         "certaintyAutoPushThreshold":0.42}
        """
        let s = try JSONDecoder().decode(AmbitickSettings.self, from: Data(json.utf8))
        let defs = AmbitickSettings(opBaseURL: "")
        try expectEq(s.opBaseURL, "https://op.example.com", "OP URL survives the bad fields")
        try expectEq(s.emailMatchOrder, EmailMatchLevel.defaultOrder, "bad ladder → default order")
        try expectEq(s.timeViewOpenMode, defs.timeViewOpenMode, "bad enum → default")
        try expectEq(s.menuTaskChars, defs.menuTaskChars, "type-mismatched field → default")
        try expectEq(s.certaintyAutoPushThreshold, 0.42, "good fields still decode normally")
    }

    c.check("defaults") {
        let s = AmbitickSettings(opBaseURL: "https://op.example.com")
        try expectEq(s.certaintyAutoPushThreshold, 0.8)
        try expectEq(s.statusOrder, ["Now", "Next", "Open", "Closed"])
        try expect(!s.showPercent)
        try expect(!s.autoComment, "auto comments are opt-in (Martin: window details are noise)")
        try expect(!s.trackLeisureLocally)
        try expectEq(s.colourLow, "#FF3B30")
        try expectEq(s.colourHigh, "#34C759")
    }

    c.check("never-auto-push is representable") {
        var s = AmbitickSettings(opBaseURL: "https://op.example.com")
        s.certaintyAutoPushThreshold = 1.01   // the "101%": nothing auto-pushes
        try expect(s.certaintyAutoPushThreshold > 1.0)
    }

    c.check("file store round-trip and missing file") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambitick-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<AmbitickSettings>(
            url: dir.appendingPathComponent("settings.json"))
        try expectNil(try store.load())
        var s = AmbitickSettings(opBaseURL: "https://op.example.com")
        s.defaultActivityID = 4
        s.activityOverrides[.op(42)] = 9
        s.activityOverrides[.remote("guid-x")] = 3          // .remote keys survive
        s.taskColours[TaskRef.remote("guid-x").storageKey] = "#123456"
        try store.save(s)
        try expectEq(try store.load(), s)
    }
}

// MARK: - End-to-end (plan task 14)

func endToEndChecks(_ c: Checks) async {
    await c.check("a full tracked stretch reaches OpenProject") {
        let base = Date(timeIntervalSince1970: 1_750_000_080)   // minute-aligned
        func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

        let tasks = [WorkTask(ref: .op(1), subject: "Ambitick build", status: "Now")]
        let journal = InMemoryJournalStore()
        let transport = MockTransport()
        transport.responses = [(201, "{}")]
        let backend = OPBackend(baseURL: URL(string: "https://op.example.com")!,
                                apiKey: "k", transport: transport)
        let attributor = Attributor(instanceHost: "op.example.com")
        let tracker = SessionTracker(attributor: attributor,
                                     config: TrackerConfig()) { tasks }
        tracker.onSession = { try? journal.save($0) }
        tracker.onReview = { try? journal.save($0) }

        // 1. open WP 1 in OP -> auto-start at the inferred ceiling (0.95)
        tracker.handle(.focus(ActivitySignal(
            app: "Chrome", windowTitle: "WP1",
            tabURL: "https://op.example.com/work_packages/1", timestamp: t(0))))
        // 2. switch to Ghostty; user confirms the task via the popover
        tracker.handle(.focus(ActivitySignal(app: "Ghostty", windowTitle: "Ambitick",
                                             timestamp: t(20))))
        tracker.confirm(task: .op(1), at: t(25))
        // 3. keep working in the same window
        tracker.handle(.focus(ActivitySignal(app: "Ghostty", windowTitle: "Ambitick",
                                             timestamp: t(600))))
        tracker.handle(.input(t(1190)))
        // 4. stop after 20 min
        tracker.stop(at: t(1200))

        let sessions = try journal.allSessions()
        try expectEq(sessions.count, 1)
        try expectEq(sessions[0].task, .op(1))
        try expectEq(sessions[0].start, t(0))
        try expectEq(sessions[0].end, t(1200))
        try expect(sessions[0].certainty >= 0.95,
                   "confirm lifts the in-flight span; got \(sessions[0].certainty)")

        // 5. sync pushes exactly one PT0H20M entry
        let engine = SyncEngine(journal: journal, backend: backend)
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: true)
        try expectEq(pushed, 1)
        let body = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        try expectEq(body["hours"] as? String, "PT0H20M")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8), [])
    }
}

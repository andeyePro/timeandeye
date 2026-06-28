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

    c.check("mark pushed records the OP entry id") {
        let s = make()
        let a = session(0.9)
        try s.save(a)
        try s.markPushed(a.id, opTimeEntryID: 977)
        try expectEq(try s.sessions(needingPushAtOrAbove: 0.8), [])
        try expectEq(try s.allSessions().first?.pushedToOP, true)
        try expectEq(try s.allSessions().first?.opTimeEntryID, 977)
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
        let client = OPClient(baseURL: URL(string: "https://op.example.com")!,
                              apiKey: "k", transport: transport)
        return (SyncEngine(journal: journal, client: client), journal, transport)
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

    c.check("parses valid response") {
        let json = """
        {"assignments": [
          {"segment": "\(segID.uuidString)", "task": 1},
          {"segment": "\(segID.uuidString)", "task": "do-not-track"}
        ]}
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID])
        try expectEq(parsed, [
            AIAssist.Assignment(segmentID: segID, target: .task(.op(1))),
            AIAssist.Assignment(segmentID: segID, target: .doNotTrack),
        ])
    }

    c.check("skips unknown segments, rejects garbage") {
        // A stray/hallucinated uuid must NOT throw away the whole batch — it is
        // skipped and the matching assignments still apply.
        let mixed = try AIAssist.parseResponse(
            #"{"assignments": [{"segment": "\#(UUID().uuidString)", "task": 1}, {"segment": "\#(segID.uuidString)", "task": 2}]}"#,
            validSegmentIDs: [segID])
        try expectEq(mixed, [AIAssist.Assignment(segmentID: segID, target: .task(.op(2)))])
        try expectThrows("non-JSON must throw") {
            _ = try AIAssist.parseResponse("not json", validSegmentIDs: [segID])
        }
        try expectThrows("boolean task must throw") {
            _ = try AIAssist.parseResponse(
                #"{"assignments": [{"segment": "\#(segID.uuidString)", "task": true}]}"#,
                validSegmentIDs: [segID])
        }
    }

    c.check("tolerates code-fence wrapping") {
        let json = """
        ```json
        {"assignments": [{"segment": "\(segID.uuidString)", "task": 1}]}
        ```
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID])
        try expectEq(parsed.count, 1)
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
        let client = OPClient(baseURL: URL(string: "https://op.example.com")!,
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
        let engine = SyncEngine(journal: journal, client: client)
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: true)
        try expectEq(pushed, 1)
        let body = try unwrap(try JSONSerialization.jsonObject(
            with: unwrap(transport.requests[0].httpBody)) as? [String: Any])
        try expectEq(body["hours"] as? String, "PT0H20M")
        try expectEq(try journal.sessions(needingPushAtOrAbove: 0.8), [])
    }
}

import Foundation
import AmbitickCore
import AmbitickMac

// Headless end-to-end: replay a realistic tracked stretch through the REAL
// pipeline (attributor -> tracker -> sqlite journal -> sync) against a REAL
// OpenProject instance, then read back what OP stored and clean up.
//
// Usage: swift run AmbitickIntegration <base-url> <api-key-file>
// Safety: refuses to run unless the key authenticates as a user whose name
// contains "Claude" (test account), and only touches its own scratch WP.

func fail(_ message: String) -> Never {
    print("INTEGRATION FAIL: \(message)")
    exit(1)
}

guard CommandLine.arguments.count >= 3,
      let baseURL = URL(string: CommandLine.arguments[1]) else {
    fail("usage: AmbitickIntegration <base-url> <api-key-file> [keep]")
}
let keepEntries = CommandLine.arguments.contains("keep")
let keyFile = CommandLine.arguments[2]
guard let rawKey = try? String(contentsOfFile: keyFile, encoding: .utf8) else {
    fail("cannot read key file \(keyFile)")
}
let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        try await run()
    } catch {
        fail("\(error)")
    }
    semaphore.signal()
}

func api(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    // String-concat, NOT appendingPathComponent: the latter percent-encodes
    // "?" into the path and OP 404s.
    let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString
        : baseURL.absoluteString + "/"
    guard let url = URL(string: base + path) else { fail("bad url \(path)") }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Basic " + Data("apikey:\(apiKey)".utf8).base64EncodedString(),
                 forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) || status == 204 else {
        throw NSError(domain: "integration", code: status,
                      userInfo: [NSLocalizedDescriptionKey:
                        "\(method) \(path) -> \(status): \(String(data: data, encoding: .utf8) ?? "")"])
    }
    if data.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func run() async throws {
    // 1. Identity guard: tests must run as the Claude test account.
    let me = try await api("GET", "api/v3/users/me")
    let myName = me["name"] as? String ?? "?"
    guard myName.localizedCaseInsensitiveContains("claude") else {
        fail("key authenticates as '\(myName)' - refusing to test with a non-Claude account")
    }
    print("running as: \(myName)")

    // 2. Scratch work package (find by subject, else create in the IT project).
    let scratchSubject = "Ambitick integration scratch (auto-created, safe to delete)"
    var scratchID: Int?
    let filters = #"[{"subject":{"operator":"~","values":["Ambitick integration scratch"]}}]"#
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    let found = try await api("GET", "api/v3/work_packages?filters=\(filters)&pageSize=5")
    if let embedded = found["_embedded"] as? [String: Any],
       let elements = embedded["elements"] as? [[String: Any]],
       let first = elements.first, let id = first["id"] as? Int {
        scratchID = id
    }
    if scratchID == nil {
        let created = try await api("POST", "api/v3/projects/8/work_packages",
                                    body: ["subject": scratchSubject])
        scratchID = created["id"] as? Int
    }
    guard let wpID = scratchID else { fail("could not find or create scratch WP") }
    print("scratch WP: #\(wpID)")

    // Pre-clean: leftovers from aborted runs must not pollute verification.
    func scratchEntriesPre() async throws -> [[String: Any]] {
        let list = try await api("GET", "api/v3/time_entries?pageSize=100")
        let all = ((list["_embedded"] as? [String: Any])?["elements"] as? [[String: Any]]) ?? []
        return all.filter {
            let href = (($0["_links"] as? [String: Any])?["workPackage"] as? [String: Any])?["href"] as? String
            return href?.hasSuffix("/work_packages/\(wpID)") == true
        }
    }
    for stale in try await scratchEntriesPre() {
        if let id = stale["id"] as? Int {
            _ = try? await api("DELETE", "api/v3/time_entries/\(id)")
        }
    }

    // 3. Replay a tracked stretch through the real pipeline.
    let host = baseURL.host ?? ""
    let attributor = Attributor(instanceHost: host)
    let journalPath = NSTemporaryDirectory() + "ambitick-integration-\(UUID().uuidString).sqlite"
    let journal = try SQLiteJournalStore(path: journalPath)
    let tasks = [WorkTask(ref: .op(wpID), subject: scratchSubject, status: "Now")]
    let tracker = SessionTracker(attributor: attributor, config: TrackerConfig()) { tasks }
    tracker.onSession = { try? journal.save($0) }
    tracker.onReview = { try? journal.save($0) }

    let t0 = Date().addingTimeInterval(-3600)   // an hour ago, today
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // open the scratch WP page -> auto-start
    tracker.handle(.focus(ActivitySignal(
        app: "Chrome", windowTitle: "WP",
        tabURL: "\(baseURL.absoluteString)work_packages/\(wpID)", timestamp: t(0))))
    guard case .tracking(.task(.op(wpID)), _) = tracker.state else {
        fail("OP page did not auto-start tracking (state \(tracker.state))")
    }
    // move to the working window, confirm, keep working with input ticks
    tracker.handle(.focus(ActivitySignal(app: "Ghostty", windowTitle: "IntegrationWin",
                                         timestamp: t(20))))
    tracker.confirm(task: .op(wpID), at: t(25))
    tracker.handle(.input(t(200)))
    tracker.handle(.input(t(400)))
    tracker.stop(at: t(600))

    let sessions = try journal.allSessions()
    guard sessions.count == 1, sessions[0].certainty >= 0.8 else {
        fail("expected one confident session, got \(sessions)")
    }

    // 4. Real push.
    let backend = OPBackend(baseURL: baseURL, apiKey: apiKey, transport: URLSessionTransport())
    backend.onDebug = { print("BACKEND DEBUG: \($0)") }
    let engine = SyncEngine(journal: journal, backend: backend)
    engine.onDebug = { print("SYNC DEBUG: \($0)") }
    let pushed = try await engine.pushEligible(threshold: 0.8, includeComments: true)
    guard pushed == 1 else { fail("expected 1 pushed entry, got \(pushed)") }
    guard backend.startTimesSupported else { fail("instance rejected startTime") }

    // 5. Read back what OP stored.
    // Client-side filtering: the server-side work-package filter name varies
    // across OP versions and 400s unhelpfully.
    func scratchEntries() async throws -> [[String: Any]] {
        let list = try await api("GET", "api/v3/time_entries?pageSize=100")
        let all = ((list["_embedded"] as? [String: Any])?["elements"] as? [[String: Any]]) ?? []
        return all.filter {
            let href = (($0["_links"] as? [String: Any])?["workPackage"] as? [String: Any])?["href"] as? String
            return href?.hasSuffix("/work_packages/\(wpID)") == true
        }
    }
    let entries = try await scratchEntries()
    guard !entries.isEmpty else {
        fail("pushed entry not found on scratch WP")
    }
    var verified = false
    for entry in entries {
        defer {
            // 6. Clean up scratch entries (unless asked to keep for inspection).
            if !keepEntries, let id = entry["id"] as? Int {
                Task { _ = try? await api("DELETE", "api/v3/time_entries/\(id)") }
            }
        }
        guard entry["hours"] as? String == "PT10M" else { continue }
        guard let start = entry["startTime"] as? String, !start.isEmpty else {
            fail("entry stored WITHOUT startTime - calendar would not place it")
        }
        let comment = (entry["comment"] as? [String: Any])?["raw"] as? String ?? ""
        guard comment.contains("Ghostty") else {
            fail("auto-comment missing, got '\(comment)'")
        }
        print("verified entry: PT10M, startTime \(start), comment '\(comment)'")
        verified = true
    }
    guard verified else { fail("no entry matched expected PT10M shape") }
    // allow deletes to fly
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let remaining = (try await scratchEntries()).count
    print("cleanup: \(remaining) entries remain on scratch WP")
    print("INTEGRATION PASS")
}

semaphore.wait()

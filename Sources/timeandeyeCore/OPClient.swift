import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injection point so checks never hit the network. The app supplies a
/// URLSession-backed implementation.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct OPTimeActivity: Equatable, Codable, Sendable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

package enum OPClientError: Error {
    case httpStatus(Int, String)
    case malformedResponse(String)
}

package final class OPClient {
    private let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport

    package init(baseURL: URL, apiKey: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    package var instanceHost: String { baseURL.host ?? "" }

    // MARK: - Requests

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET",
                         body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.httpBody = body
        let token = Data("apikey:\(apiKey)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw OPClientError.httpStatus(response.statusCode,
                                           String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Work packages

    private struct WPPage: Decodable {
        struct Embedded: Decodable {
            let elements: [WPElement]
        }
        let total: Int
        let count: Int
        let _embedded: Embedded
    }

    private struct WPElement: Decodable {
        struct Links: Decodable {
            struct Titled: Decodable { let title: String? }
            /// Title plus href: the project link's href carries the STABLE
            /// project id ("/api/v3/projects/14"), which the billable flag
            /// map keys on — titles are rename-fragile.
            struct TitledLink: Decodable {
                let title: String?
                let href: String?
            }
            let status: Titled?
            let project: TitledLink?
            let assignee: Titled?
        }
        let id: Int
        let subject: String
        let _links: Links
    }

    /// The trailing numeric id of a project href ("/api/v3/projects/14" →
    /// "14"); nil when absent or non-numeric (never guess an identity).
    static func projectID(fromHref href: String?) -> String? {
        guard let last = href?.split(separator: "/").last, Int(last) != nil else {
            return nil
        }
        return String(last)
    }

    /// Pages through ALL work packages visible to the API key — including
    /// closed ones (the API defaults to open-only, which hid actively-used
    /// Closed tasks like Timesheets). NB: OpenProject's `offset` query
    /// parameter is a 1-BASED PAGE NUMBER, not an element offset.
    package func fetchTasks(pageSize: Int = 100) async throws -> [WorkTask] {
        var tasks: [WorkTask] = []
        var page = 1
        while true {
            let data = try await send(request(
                path: "api/v3/work_packages",
                query: [URLQueryItem(name: "pageSize", value: String(pageSize)),
                        URLQueryItem(name: "offset", value: String(page)),
                        URLQueryItem(name: "filters",
                                     value: #"[{"status":{"operator":"*","values":[]}}]"#)]))
            let decoded = try decode(WPPage.self, from: data)
            tasks += decoded._embedded.elements.map {
                WorkTask(ref: .op($0.id), subject: $0.subject,
                         project: $0._links.project?.title,
                         projectID: Self.projectID(fromHref: $0._links.project?.href),
                         status: $0._links.status?.title ?? "Unknown",
                         assignee: $0._links.assignee?.title)
            }
            page += 1
            if tasks.count >= decoded.total || decoded.count == 0 { break }
        }
        return tasks
    }

    /// Who the API key authenticates as — time entries are attributed to this
    /// user, so surfacing it prevents silent wrong-account logging.
    package func fetchMe() async throws -> String {
        struct Me: Decodable { let name: String }
        let data = try await send(request(path: "api/v3/users/me"))
        return try decode(Me.self, from: data).name
    }

    // MARK: - Time entry activities

    private struct FormResponse: Decodable {
        struct Embedded: Decodable {
            struct Schema: Decodable {
                struct Activity: Decodable {
                    struct Inner: Decodable { let allowedValues: [OPTimeActivity] }
                    let _embedded: Inner
                }
                let activity: Activity
            }
            let schema: Schema
        }
        let _embedded: Embedded
    }

    /// Allowed activities come from the time-entry creation form schema.
    package func fetchActivities() async throws -> [OPTimeActivity] {
        let data = try await send(request(path: "api/v3/time_entries/form",
                                          method: "POST", body: Data("{}".utf8)))
        return try decode(FormResponse.self, from: data)
            ._embedded.schema.activity._embedded.allowedValues
    }

    // MARK: - Time entries

    /// activityID nil = omit the link; OP applies its server-side default.
    /// (Some instances – Martin's included – run without visible activities.)
    /// startTime (ISO 8601 UTC) places the entry in OP's calendar views; only
    /// sent when non-nil because instances can have the feature disabled.
    /// Returns the created entry's id so timeline edits can PATCH it later.
    @discardableResult
    package func createTimeEntry(workPackageID: Int, start: Date, duration: TimeInterval,
                                activityID: Int?, comment: String?,
                                startTime: String? = nil) async throws -> Int? {
        let body = try Self.timeEntryPayload(workPackageID: workPackageID, start: start,
                                             duration: duration, activityID: activityID,
                                             comment: comment, startTime: startTime)
        let data = try await send(request(path: "api/v3/time_entries", method: "POST", body: body))
        struct Created: Decodable { let id: Int? }
        // Don't swallow an undecodable 2xx body with `try?`: a body we can't
        // parse means OP may have created an entry whose id we can't recover,
        // i.e. an un-PATCHable/-DELETE-able orphan. Surface it via the shared
        // decode helper (-> .malformedResponse). A valid but id-less body like
        // `{}` still decodes to nil and returns nil.
        return try decode(Created.self, from: data).id
    }

    /// Timeline edits: rewrite an existing entry in place.
    package func updateTimeEntry(id: Int, workPackageID: Int, start: Date,
                                duration: TimeInterval, activityID: Int?,
                                comment: String?, startTime: String? = nil) async throws {
        let body = try Self.timeEntryPayload(workPackageID: workPackageID, start: start,
                                             duration: duration, activityID: activityID,
                                             comment: comment, startTime: startTime)
        _ = try await send(request(path: "api/v3/time_entries/\(id)", method: "PATCH", body: body))
    }

    /// Post a comment to a work package's activity feed (the task's journal),
    /// so a 'comment to task' note is findable on the task itself rather than
    /// buried on a single time entry.
    package func addWorkPackageComment(id: Int, text: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["comment": ["raw": text]])
        _ = try await send(request(path: "api/v3/work_packages/\(id)/activities",
                                   method: "POST", body: body))
    }

    package func deleteTimeEntry(id: Int) async throws {
        _ = try await send(request(path: "api/v3/time_entries/\(id)", method: "DELETE"))
    }

    /// PATCH only the comment (used by the duplicate-reconcile, which folds the
    /// deleted entries' comments into the survivor without touching its times).
    package func updateTimeEntryComment(id: Int, comment: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["comment": ["raw": comment]])
        _ = try await send(request(path: "api/v3/time_entries/\(id)", method: "PATCH", body: body))
    }

    private struct TEPage: Decodable {
        struct Embedded: Decodable { let elements: [TEElement] }
        let total: Int
        let count: Int
        let _embedded: Embedded
    }
    private struct TEElement: Decodable {
        struct Links: Decodable {
            struct Href: Decodable { let href: String? }
            struct Titled: Decodable { let title: String? }
            let workPackage: Href?
            let activity: Titled?
        }
        struct Comment: Decodable { let raw: String? }
        let id: Int
        let hours: String?
        let spentOn: String?
        let startTime: String?
        let comment: Comment?
        let createdAt: String?
        let updatedAt: String?
        let _links: Links
    }

    /// Read back the current user's time entries spent in [from, to] — the input
    /// to the duplicate-entry reconcile (the MCP exposes neither start times nor
    /// a delete verb, so this has to come straight from the API).
    package func listTimeEntries(from: Date, to: Date, pageSize: Int = 200) async throws -> [OPTimeEntry] {
        let fromDay = Self.dayFormatter.string(from: from)
        let toDay = Self.dayFormatter.string(from: to)
        let filters = "[{\"spentOn\":{\"operator\":\"<>d\",\"values\":[\"\(fromDay)\",\"\(toDay)\"]}},"
            + "{\"user\":{\"operator\":\"=\",\"values\":[\"me\"]}}]"
        var out: [OPTimeEntry] = []
        var fetched = 0
        var page = 1
        while true {
            let data = try await send(request(
                path: "api/v3/time_entries",
                query: [URLQueryItem(name: "pageSize", value: String(pageSize)),
                        URLQueryItem(name: "offset", value: String(page)),
                        URLQueryItem(name: "filters", value: filters)]))
            let decoded = try decode(TEPage.self, from: data)
            fetched += decoded.count
            out += decoded._embedded.elements.compactMap(Self.parse)
            page += 1
            if fetched >= decoded.total || decoded.count == 0 { break }
        }
        return out
    }

    private static func parse(_ e: TEElement) -> OPTimeEntry? {
        guard let href = e._links.workPackage?.href,
              let wp = Int(href.split(separator: "/").last.map(String.init) ?? ""),
              let spentOn = e.spentOn else { return nil }
        let hm = e.startTime.map { String($0.prefix(5)) }
        let hasStart = (hm?.isEmpty == false)
        return OPTimeEntry(id: e.id, workPackageID: wp,
                           start: startDate(spentOn: spentOn, startTime: e.startTime),
                           durationSeconds: parseISO8601Duration(e.hours ?? ""),
                           comment: e.comment?.raw,
                           createdAt: parseStamp(e.createdAt),
                           updatedAt: parseStamp(e.updatedAt),
                           activity: e._links.activity?.title,
                           hasStart: hasStart)
    }

    /// OP's full ISO-8601 timestamps — tolerate fractional seconds (".000Z"),
    /// which the default formatter rejects (the cause of "created ?").
    static func parseStamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Combine OP's `spentOn` (local day) + `startTime` (HH:MM) into an instant,
    /// in the user's timezone (matching how entries are written). No startTime →
    /// local midnight of that day.
    static func startDate(spentOn: String, startTime: String?) -> Date {
        let hm = startTime.map { String($0.prefix(5)) } ?? "00:00"
        return dateTimeFormatter.date(from: "\(spentOn) \(hm)")
            ?? dayFormatter.date(from: spentOn) ?? Date()
    }

    /// Parse an OP `hours` value ("PT1H30M", "PT45M", "PT2H") to seconds — the
    /// inverse of `iso8601Duration`.
    static func parseISO8601Duration(_ s: String) -> TimeInterval {
        guard s.hasPrefix("PT") else { return 0 }
        var hours = 0, minutes = 0, num = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber { num.append(ch) }
            else if ch == "H" { hours = Int(num) ?? 0; num = "" }
            else if ch == "M" { minutes = Int(num) ?? 0; num = "" }
            else { num = "" }
        }
        return TimeInterval(hours * 3600 + minutes * 60)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func timeEntryPayload(workPackageID: Int, start: Date,
                                         duration: TimeInterval, activityID: Int?,
                                         comment: String?, startTime: String?) throws -> Data {
        var links: [String: [String: String]] = [
            "workPackage": ["href": "/api/v3/work_packages/\(workPackageID)"],
        ]
        if let activityID {
            links["activity"] = ["href": "/api/v3/time_entries/activities/\(activityID)"]
        }
        var payload: [String: Any] = [
            "hours": iso8601Duration(duration),
            "spentOn": dayFormatter.string(from: start),
            "_links": links,
        ]
        if let startTime {
            payload["startTime"] = startTime
        }
        if let comment {
            payload["comment"] = ["raw": comment]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OPClientError.malformedResponse(String(describing: error))
        }
    }

    static func iso8601Duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return "PT\(h)H\(m)M"
    }

    /// LOCAL day, not UTC: OP validates spentOn against startTime rendered in
    /// the user's profile timezone, so a UTC day 422s for an hour after local
    /// midnight (BST) and the entry silently lost its start time.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

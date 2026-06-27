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

public enum OPClientError: Error {
    case httpStatus(Int, String)
    case malformedResponse(String)
}

public final class OPClient {
    private let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport

    public init(baseURL: URL, apiKey: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public var instanceHost: String { baseURL.host ?? "" }

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
            let status: Titled?
            let project: Titled?
            let assignee: Titled?
        }
        let id: Int
        let subject: String
        let _links: Links
    }

    /// Pages through ALL work packages visible to the API key — including
    /// closed ones (the API defaults to open-only, which hid actively-used
    /// Closed tasks like Timesheets). NB: OpenProject's `offset` query
    /// parameter is a 1-BASED PAGE NUMBER, not an element offset.
    public func fetchTasks(pageSize: Int = 100) async throws -> [WorkTask] {
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
    public func fetchMe() async throws -> String {
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
    public func fetchActivities() async throws -> [OPTimeActivity] {
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
    public func createTimeEntry(workPackageID: Int, start: Date, duration: TimeInterval,
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
    public func updateTimeEntry(id: Int, workPackageID: Int, start: Date,
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
    public func addWorkPackageComment(id: Int, text: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["comment": ["raw": text]])
        _ = try await send(request(path: "api/v3/work_packages/\(id)/activities",
                                   method: "POST", body: body))
    }

    public func deleteTimeEntry(id: Int) async throws {
        _ = try await send(request(path: "api/v3/time_entries/\(id)", method: "DELETE"))
    }

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

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import timeandeyeCore

/// URLSession-backed transport for real backends (Mac and iOS alike).
public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

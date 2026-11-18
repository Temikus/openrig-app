import Foundation
import RigModel

public enum DaemonError: Error, Sendable, Equatable {
    /// Nothing answered: the daemon is stopped or the port is wrong.
    case unreachable(String)
    case http(status: Int, path: String)
    case decoding(path: String, message: String)
}

/// Read-only access to the daemon's HTTP API. Writes go through the `rig` CLI instead.
public struct DaemonHTTP: Sendable {
    public var baseURL: URL
    var session: URLSession
    var timeout: TimeInterval

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 5) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func health() async throws(DaemonError) -> DaemonHealth {
        try await get("/healthz")
    }

    public func rigs() async throws(DaemonError) -> [RigSummary] {
        try await get("/api/ps")
    }

    public func graph(rigID: String) async throws(DaemonError) -> RigGraph {
        try await get("/api/rigs/\(rigID)/graph")
    }

    /// All queue rows whose source or destination is in the rig, newest first.
    public func queue(rigName: String, limit: Int = 500) async throws(DaemonError) -> [QItem] {
        try await get("/api/queue/list", query: ["rig": rigName, "limit": String(limit)])
    }

    public func seatStatus(session: String) async throws(DaemonError) -> SeatStatusReport {
        try await get("/api/seat/status/\(session)")
    }

    /// Every workflow instance the daemon knows, with the spec each one started from.
    public func workflows() async throws(DaemonError) -> [WorkflowInstance] {
        try await get("/api/workflow/list")
    }

    /// People and shared channels registered with the gateway, and the default person.
    public func participants() async throws(DaemonError) -> GatewayParticipants {
        try await get("/api/gateway/participants")
    }

    public func qitem(id: String) async throws(DaemonError) -> QItem {
        try await get("/api/queue/\(id)")
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws(DaemonError) -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) })
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(status: http.statusCode, path: path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(path: path, message: String(describing: error))
        }
    }
}

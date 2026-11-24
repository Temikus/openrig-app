import Foundation
import Network

/// One call from the phone, as a frame on its `RelayChannel`.
public struct RelayRequest: Codable, Sendable, Equatable {
    public var method: String
    /// Path and query, e.g. `/api/apps/v1/needs-me`.
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// The daemon's answer, in one frame or, for a stream such as `/api/apps/v1/events`, several. The last has `more`
/// false.
public struct RelayResponse: Codable, Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var more: Bool

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), more: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.more = more
    }
}

/// What the relay passes on: the app contract, and nothing that issues or revokes credentials.
public enum RelayPolicy {
    static let prefix = "/api/apps/v1/"
    static let methods: Set<String> = ["GET", "POST"]
    /// The headers the phone's client sends. Anything else (cookies, `X-OpenRig-Session`) stays behind.
    static let headers: Set<String> = ["authorization", "accept", "content-type", "last-event-id"]

    public static func allows(_ request: RelayRequest) -> Bool {
        guard methods.contains(request.method), request.path.hasPrefix(prefix),
            let parts = URLComponents(string: request.path), parts.scheme == nil, parts.host == nil
        else { return false }
        // Decoded, so "%2e%2e" can't stand in for "..".
        let path = parts.percentEncodedPath.removingPercentEncoding ?? ""
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix(prefix),
            !segments.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty && $0 != segments.last })
        else {
            return false
        }
        return !path.hasPrefix(prefix + "credentials")
    }
}

extension RelayChannel {
    /// Sends one call and reads its answer, every frame of it.
    public func call(_ request: RelayRequest) async throws -> [RelayResponse] {
        try await send(JSONEncoder().encode(request))
        var frames: [RelayResponse] = []
        repeat {
            frames.append(try JSONDecoder().decode(RelayResponse.self, from: try await receive()))
        } while frames.last?.more == true
        return frames
    }
}

/// The Mac's relay: a TLS-PSK listener that passes a paired phone's app-contract calls to the daemon on loopback.
public final class RelayServer: @unchecked Sendable {
    public typealias Forward = @Sendable (RelayRequest) -> AsyncThrowingStream<RelayResponse, any Error>

    private let keys: [String: Data]
    private let host: String
    private let port: UInt16
    private let forward: Forward
    private let lock = NSLock()
    private var listener: NWListener?

    /// - Parameters:
    ///   - keys: each paired phone's secret, by its credential id.
    ///   - host: the address to listen on. Seats' runs and tests use 127.0.0.1 only.
    ///   - port: the port to try first; 0 takes any.
    public init(keys: [String: Data], host: String, port: UInt16, forward: @escaping Forward) {
        self.keys = keys
        self.host = host
        self.port = port
        self.forward = forward
    }

    /// Starts listening and returns the port in use. A taken port falls back to a free one.
    public func start() async throws -> UInt16 {
        do {
            return try await listen(on: port)
        } catch  where port != 0 {
            return try await listen(on: 0)
        }
    }

    public func stop() {
        lock.withLock { listener }?.cancel()
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters = RelayLink.serverParameters(keys: keys)
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let once = Once()
        let bound = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        lock.withLock { self.listener = listener }
        return bound
    }

    private func serve(_ connection: NWConnection) {
        let channel = RelayChannel(connection)
        connection.start(queue: .global())
        let forward = self.forward
        Task {
            defer { channel.close() }
            while let frame = try? await channel.receive() {
                guard let request = try? JSONDecoder().decode(RelayRequest.self, from: frame) else { return }
                guard RelayPolicy.allows(request) else {
                    try await channel.reply(RelayResponse(status: 403, body: Data("Not available to a phone".utf8)))
                    continue
                }
                var last: RelayResponse?
                do {
                    for try await response in forward(request) {
                        try await channel.reply(response)
                        last = response
                    }
                } catch {
                    let failed = RelayResponse(status: 502, body: Data("The daemon didn't answer".utf8))
                    try await channel.reply(failed)
                    last = failed
                }
                if last?.more != false { try await channel.reply(RelayResponse(status: last?.status ?? 502)) }
            }
        }
    }

    /// The daemon's request for a phone's call: same method, path, query and body, and only the contract's headers.
    public static func urlRequest(for request: RelayRequest, daemon: URL) -> URLRequest {
        var url = URLComponents(url: daemon, resolvingAgainstBaseURL: false)!
        let parts = URLComponents(string: request.path)
        url.percentEncodedPath = parts?.percentEncodedPath ?? ""
        url.percentEncodedQuery = parts?.percentEncodedQuery
        var built = URLRequest(url: url.url!, timeoutInterval: 30)
        built.httpMethod = request.method
        built.httpBody = request.body
        for (name, value) in request.headers where RelayPolicy.headers.contains(name.lowercased()) {
            built.setValue(value, forHTTPHeaderField: name)
        }
        return built
    }

    /// Forwards to the daemon on loopback. An event stream comes back a line at a time; anything else whole.
    public static func daemonForwarder(_ daemon: URL, session: URLSession = .shared) -> Forward {
        { request in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let (bytes, response) = try await session.bytes(for: urlRequest(for: request, daemon: daemon))
                        let http = response as? HTTPURLResponse
                        let status = http?.statusCode ?? 502
                        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                        let headers = type.isEmpty ? [:] : ["Content-Type": type]
                        if type.hasPrefix("text/event-stream") {
                            for try await line in bytes.lines {
                                continuation.yield(
                                    RelayResponse(
                                        status: status, headers: headers, body: Data((line + "\n").utf8), more: true))
                            }
                            continuation.yield(RelayResponse(status: status, headers: headers))
                        } else {
                            var body = Data()
                            for try await byte in bytes { body.append(byte) }
                            continuation.yield(RelayResponse(status: status, headers: headers, body: body))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

extension RelayChannel {
    fileprivate func reply(_ response: RelayResponse) async throws {
        try await send(JSONEncoder().encode(response))
    }
}

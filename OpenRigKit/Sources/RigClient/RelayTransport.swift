import Foundation
import Network
import OSLog
import Synchronization

/// Carries `AppClient`'s HTTP calls over the Mac's relay, so the app contract works unchanged on the Wi-Fi.
///
/// URLSession can't speak TLS-PSK, so a URL protocol takes requests for `openrig-relay://<identity>@host:port/…`.
/// Each request opens its own `RelayChannel` (the channel carries one call at a time, and the event stream holds one
/// open), sends it as a `RelayRequest`, and passes the response frames back as they come.
public enum RelayTransport {
    public static let scheme = "openrig-relay"
    /// The handshake's result: the suite, or why it failed. No secret, token or body is logged.
    static let log = Logger(subsystem: "dev.openrig.relay", category: "transport")

    /// Secrets by identity (the credential id), for the URL protocol to find. Never in the URL.
    static let secrets = Mutex<[String: Data]>([:])
    /// The suite the last relay handshake settled on. For the check that iOS negotiates ECDHE_PSK.
    public static var lastNegotiatedSuite: UInt16? { lastSuite.withLock { $0 } }
    static let lastSuite = Mutex<UInt16?>(nil)

    /// Drops a pairing's secret: on Unpair, or when another code replaces it.
    public static func forget(identity: String) { _ = secrets.withLock { $0.removeValue(forKey: identity) } }

    /// An `AppClient` that reaches the daemon through the relay at `host:port`.
    public static func client(
        host: String, port: UInt16, identity: String, secret: Data, token: String, actor: String,
        timeout: TimeInterval = 10
    ) -> AppClient {
        secrets.withLock { $0[identity] = secret }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.user = identity
        parts.host = host
        parts.port = Int(port)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayURLProtocol.self]
        return AppClient(
            baseURL: parts.url!, token: token, actor: actor, session: URLSession(configuration: config),
            timeout: timeout)
    }
}

final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var channel: RelayChannel?
        var stopped = false
    }
    private let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == RelayTransport.scheme }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let started = Task { await self.load(request) }
        state.withLock { $0.task = started }
    }

    /// Closes the channel at once: a pending `receive` doesn't wake for a cancel, and an events stream would
    /// otherwise stay open until its next frame.
    override func stopLoading() {
        let (task, channel) = state.withLock { s in
            s.stopped = true
            return (s.task, s.channel)
        }
        task?.cancel()
        channel?.close()
    }

    /// A URL error with words for the person: the bare codes read "NSURLErrorDomain error -1004".
    static func failure(_ code: URLError.Code, _ words: String) -> URLError {
        URLError(code, userInfo: [NSLocalizedDescriptionKey: words])
    }

    /// The client, until `stopLoading`: after that, URL loading wants no more calls.
    private var live: (any URLProtocolClient)? { state.withLock { $0.stopped } ? nil : client }

    private func load(_ request: URLRequest) async {
        guard let url = request.url, let host = url.host(), let port = url.port.flatMap(UInt16.init(exactly:)),
            let identity = url.user(), let secret = RelayTransport.secrets.withLock({ $0[identity] })
        else {
            live?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let channel = RelayChannel(host: host, port: port, identity: identity, secret: secret)
        defer { channel.close() }
        let stopped = state.withLock { s in
            s.channel = channel
            return s.stopped
        }
        guard !stopped else { return }
        do {
            try await channel.open(timeout: .seconds(min(request.timeoutInterval, 10)))
        } catch RelayLinkError.refused(let reason) {
            // The relay is there but doesn't know this phone's key: after Unpair the Mac forgets it. Read as 401.
            RelayTransport.log.notice("relay refused the key: \(reason, privacy: .public)")
            respond(url, status: 401, headers: [:])
            live?.urlProtocolDidFinishLoading(self)
            return
        } catch {
            RelayTransport.log.notice("relay not reached: \(String(describing: error), privacy: .public)")
            live?.urlProtocol(
                self, didFailWithError: Self.failure(.cannotConnectToHost, "Couldn't connect to the Mac's relay."))
            return
        }
        let suite = channel.negotiatedSuite
        RelayTransport.lastSuite.withLock { $0 = suite }
        RelayTransport.log.notice("relay negotiated suite 0x\(String(suite ?? 0, radix: 16), privacy: .public)")

        let call = RelayRequest(
            method: request.httpMethod ?? "GET",
            path: url.path(percentEncoded: true) + (url.query(percentEncoded: true).map { "?" + $0 } ?? ""),
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        do {
            try await channel.send(JSONEncoder().encode(call))
            var responded = false
            while !Task.isCancelled {
                let frame = try JSONDecoder().decode(RelayResponse.self, from: try await channel.receive())
                if !responded {
                    respond(url, status: frame.status, headers: frame.headers)
                    responded = true
                }
                if !frame.body.isEmpty { live?.urlProtocol(self, didLoad: frame.body) }
                if !frame.more { break }
            }
            live?.urlProtocolDidFinishLoading(self)
        } catch {
            live?.urlProtocol(
                self,
                didFailWithError: Self.failure(.networkConnectionLost, "The connection to the Mac's relay was lost."))
        }
    }

    private func respond(_ url: URL, status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        live?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

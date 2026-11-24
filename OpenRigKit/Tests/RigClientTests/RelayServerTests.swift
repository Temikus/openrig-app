import Foundation
import Network
import Testing

@testable import RigClient

/// The Mac's relay, on 127.0.0.1 only. A phone reaches the app contract through it and nothing else.
@Suite(.serialized) struct RelayServerTests {
    let secret = RelayLink.newSecret()

    static func request(_ method: String, _ path: String, body: Data? = nil) -> RelayRequest {
        RelayRequest(method: method, path: path, headers: ["Authorization": "Bearer orapp_x"], body: body)
    }

    /// An allowlist of the routes `AppClient` calls, nothing else.
    @Test func policyAllowsOnlyTheAppContract() {
        let allowed = [
            Self.request("GET", "/api/apps/v1/capabilities"),
            Self.request("GET", "/api/apps/v1/needs-me"),
            Self.request("GET", "/api/apps/v1/events?after=Y3Vy"),
            Self.request("GET", "/api/apps/v1/requests/qitem-20261124-1a2b"),
            Self.request("GET", "/api/apps/v1/requests/qitem-1/result"),
            Self.request("GET", "/api/apps/v1/answers/7f3c2a1e-0b9d-4c5e-8f6a-1b2c3d4e5f60"),
            Self.request("POST", "/api/apps/v1/answers/7f3c2a1e-0b9d-4c5e-8f6a-1b2c3d4e5f60"),
        ]
        for request in allowed { #expect(RelayPolicy.allows(request), "\(request.method) \(request.path)") }
        let refused = [
            Self.request("GET", "/api/queue/list"),
            Self.request("POST", "/api/seat/send"),
            Self.request("GET", "/api/apps/v1/../queue/list"),
            Self.request("GET", "/api/apps/v1/%2e%2e/queue/list"),
            Self.request("GET", "/api/apps/v1//../../api/ps"),
            Self.request("GET", "/api/apps/v1/requests/a%2F..%2F..%2Fps"),
            Self.request("GET", "/api/apps/v1/requests//result/"),
            Self.request("GET", "/api/apps/v1/requests/./result"),
            Self.request("POST", "/api/apps/v1/credentials"),
            Self.request("POST", "/api/apps/v1/Credentials"),
            Self.request("DELETE", "/api/apps/v1/credentials/cred-1"),
            Self.request("DELETE", "/api/apps/v1/answers/a-1"),
            Self.request("POST", "/api/apps/v1/needs-me"),
            Self.request("GET", "/api/apps/v1/needs-me/extra"),
            Self.request("GET", "/api/apps/v1/NEEDS-ME"),
            Self.request("GET", "http://evil.test/api/apps/v1/needs-me"),
            Self.request("GET", "api/apps/v1/needs-me"),
        ]
        for request in refused { #expect(!RelayPolicy.allows(request), "\(request.method) \(request.path)") }
    }

    /// The daemon gets the path that was checked, rebuilt from its segments, not the phone's raw text.
    @Test func theCheckedPathIsWhatIsForwarded() {
        let built = RelayServer.urlRequest(
            for: Self.request("GET", "/api/apps/v1/requests/qitem-1/result?x=1"),
            daemon: URL(string: "http://127.0.0.1:7433")!)
        #expect(built.url?.absoluteString == "http://127.0.0.1:7433/api/apps/v1/requests/qitem-1/result?x=1")
    }

    @Test func anAllowedCallIsForwardedAndTheRestRefused() async throws {
        let seen = Seen()
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0) { request in
            seen.add(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(RelayResponse(status: 200, body: Data(#"{"items":[]}"#.utf8)))
                continuation.finish()
            }
        }
        let port = try await relay.start()
        defer { relay.stop() }
        let phone = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
        defer { phone.close() }
        try await phone.open()

        let answer = try await phone.call(Self.request("GET", "/api/apps/v1/needs-me"))
        #expect(answer.map(\.status) == [200])
        #expect(answer.first?.body == Data(#"{"items":[]}"#.utf8))
        let refused = try await phone.call(Self.request("GET", "/api/queue/list"))
        #expect(refused.map(\.status) == [403])
        #expect(seen.paths == ["/api/apps/v1/needs-me"], "the refused call never reached the daemon")
    }

    /// The events stream arrives as it comes, one frame per chunk, the last marked done.
    @Test func aStreamArrivesFrameByFrame() async throws {
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0) { _ in
            AsyncThrowingStream { continuation in
                for line in ["id: 1\n", "data: {}\n", "\n"] {
                    continuation.yield(RelayResponse(status: 200, body: Data(line.utf8), more: true))
                }
                continuation.finish()
            }
        }
        let port = try await relay.start()
        defer { relay.stop() }
        let phone = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
        defer { phone.close() }
        try await phone.open()
        let frames = try await phone.call(Self.request("GET", "/api/apps/v1/events"))
        #expect(frames.map { String(decoding: $0.body, as: UTF8.self) } == ["id: 1\n", "data: {}\n", "\n", ""])
        #expect(frames.map(\.more) == [true, true, true, false])
    }

    /// Turning the switch off, or Unpair (which restarts the relay without that key), must cut a phone already
    /// connected, not only stop new ones. review-code's probe.
    @Test func stopDropsConnectedPhones() async throws {
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(RelayResponse(status: 200))
                continuation.finish()
            }
        }
        let port = try await relay.start()
        let phone = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
        defer { phone.close() }
        try await phone.open()
        #expect(try await phone.call(Self.request("GET", "/api/apps/v1/needs-me")).map(\.status) == [200])
        relay.stop()
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: (any Error).self) {
            _ = try await phone.call(Self.request("GET", "/api/apps/v1/needs-me"))
        }
    }

    /// The Mac-side calls go to the desk, never to the daemon; one off the list is refused, and so is every call when
    /// no desk is given.
    @Test func macSideCallsGoToTheDesk() async throws {
        let seen = Seen()
        let forward: RelayServer.Forward = { request in
            seen.add(request)
            return AsyncThrowingStream { $0.finish() }
        }
        let desk = FakeDesk(prompt: nil)
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0, desk: desk, forward: forward)
        let port = try await relay.start()
        defer { relay.stop() }
        let phone = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
        defer { phone.close() }
        try await phone.open()
        let list = try await phone.call(RelayRequest(method: "GET", path: "/relay/v1/needs-you"))
        #expect(list.map(\.status) == [200])
        #expect(try JSONDecoder().decode(RelayNeedsYou.self, from: list.first?.body ?? Data()) == RelayNeedsYou())
        let always = try await phone.call(
            RelayRequest(
                method: "POST", path: "/relay/v1/prompts/dev-b1@openrig-app/always-allow", body: Data("{}".utf8)))
        #expect(always.map(\.status) == [403])
        #expect(seen.paths.isEmpty, "nothing reached the daemon")

        let bare = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0, forward: forward)
        let barePort = try await bare.start()
        defer { bare.stop() }
        let other = RelayChannel(host: "127.0.0.1", port: barePort, identity: "cred-a", secret: secret)
        defer { other.close() }
        try await other.open()
        #expect(try await other.call(RelayRequest(method: "GET", path: "/relay/v1/needs-you")).map(\.status) == [403])
    }

    /// A second copy of the app holds the port: the relay takes a free one, and the QR carries it.
    @Test func aTakenPortFallsBackToAFreeOne() async throws {
        let first = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0) { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let taken = try await first.start()
        defer { first.stop() }
        let second = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: taken) { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let port = try await second.start()
        defer { second.stop() }
        #expect(port != taken && port != 0)
    }

    /// Only the contract's headers go on to the daemon, and its answer comes back with its status.
    @Test func theDaemonForwarderPassesOnlyTheContractsHeaders() async throws {
        let script = Script([.status(409, Data(#"{"error":"returned"}"#.utf8))])
        let forward = RelayServer.daemonForwarder(script.baseURL, session: script.session)
        var request = Self.request("POST", "/api/apps/v1/answers/a-1?x=1", body: Data(#"{"a":1}"#.utf8))
        request.headers["Cookie"] = "session=abc"
        request.headers["X-OpenRig-Session"] = "orch-lead@openrig-app"
        var frames: [RelayResponse] = []
        for try await frame in forward(request) { frames.append(frame) }
        #expect(frames.map(\.status) == [409])
        #expect(frames.last?.more == false)
        let sent = try #require(script.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/apps/v1/answers/a-1")
        #expect(sent.query == "x=1")
        #expect(sent.authorization == "Bearer orapp_x")
        #expect(sent.body == Data(#"{"a":1}"#.utf8))

        let built = RelayServer.urlRequest(for: request, daemon: script.baseURL)
        #expect(Set(built.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["authorization"])
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RelayRequest] = []
    func add(_ request: RelayRequest) { lock.withLock { requests.append(request) } }
    var paths: [String] { lock.withLock { requests.map(\.path) } }
}

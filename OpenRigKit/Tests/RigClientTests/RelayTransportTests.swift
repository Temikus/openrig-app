import Foundation
import Network
import RigModel
import Testing

@testable import RigClient

/// The phone's app-contract client through the Mac's relay, end to end: `AppClient` → `RelayTransport` →
/// `RelayChannel` (TLS-PSK) → `RelayServer` → a scripted daemon. Every listener binds 127.0.0.1 only.
@Suite(.serialized) struct RelayTransportTests {
    let secret = RelayLink.newSecret()
    let credential = "cred-phone-1"

    /// A relay on loopback in front of `script`, holding this phone's key, or `keys` when given.
    func relay(_ script: Script, keys: [String: Data]? = nil) async throws -> (RelayServer, UInt16) {
        let server = RelayServer(
            keys: keys ?? [credential: secret], host: "127.0.0.1", port: 0,
            forward: RelayServer.daemonForwarder(script.baseURL, session: script.session))
        return (server, try await server.start())
    }

    func client(port: UInt16, secret: Data? = nil) -> AppClient {
        RelayTransport.client(
            host: "127.0.0.1", port: port, identity: credential, secret: secret ?? self.secret,
            token: "orapp_relay", actor: "human-example@external")
    }

    @Test func readsGoThroughTheRelayUnchanged() async throws {
        let script = Script([
            .status(200, try appFixture("app-capabilities")), .status(200, try appFixture("app-needs-me")),
        ])
        let (server, port) = try await relay(script)
        defer { server.stop() }
        let app = client(port: port)
        #expect(try await app.capabilities().supportsAnswering)
        #expect(try await app.needsMe().requests.count == 2)
        let seen = script.requests
        #expect(seen.map(\.path) == ["/api/apps/v1/capabilities", "/api/apps/v1/needs-me"])
        #expect(seen.last?.query == "actor=human-example@external")
        #expect(seen.last?.authorization == "Bearer orapp_relay")
    }

    /// An answer's exact bytes reach the daemon, and its receipt comes back.
    @Test func anAnswerGoesThroughWithItsBytes() async throws {
        let script = Script([.status(200, try appFixture("app-receipt-returned"))])
        let (server, port) = try await relay(script)
        defer { server.stop() }
        let body = Data(#"{"answer":{"kind":"option","optionId":"a"}}"#.utf8)
        let receipt = try await client(port: port).answer(id: "answer1234", body: body)
        #expect(receipt.fate == .returned(reply: "qitem-20261123103104-e41b"))
        #expect(script.requests.first?.method == "POST")
        #expect(script.requests.first?.path == "/api/apps/v1/answers/answer1234")
        #expect(script.requests.first?.body == body)
    }

    /// The event stream keeps the blank line that ends each message, so the phone sees each event.
    @Test func eventsComeThroughTheRelay() async throws {
        let stream = "id: c-1\nevent: invalidate\ndata: {}\n\nevent: heartbeat\ndata: {\"kind\":\"heartbeat\"}\n\n"
        let script = Script([.events(Data(stream.utf8))])
        let (server, port) = try await relay(script)
        defer { server.stop() }
        var seen: [AppEvent] = []
        for try await event in client(port: port).events() { seen.append(event) }
        #expect(seen == [.invalidate(cursor: "c-1"), .heartbeat])
    }

    /// After Unpair the Mac forgets the phone's key, so the handshake is refused: the phone reads that as unpaired.
    @Test func aRefusedKeyReadsAsUnpaired() async throws {
        let script = Script([])
        let (server, port) = try await relay(script, keys: ["someone-else": RelayLink.newSecret()])
        defer { server.stop() }
        await #expect(throws: AppError.unpaired) { try await client(port: port).capabilities() }
        #expect(script.requests.isEmpty)
    }

    /// Nothing listening is a network fault, not an unpairing.
    @Test func nothingListeningIsUnreachable() async throws {
        let (server, port) = try await relay(Script([]))
        server.stop()
        await #expect {
            try await client(port: port).capabilities()
        } throws: { error in
            if case AppError.unreachable = error { true } else { false }
        }
    }

    @Test func theTransportNegotiatesECDHEPSK() async throws {
        let script = Script([.status(200, try appFixture("app-capabilities"))])
        let (server, port) = try await relay(script)
        defer { server.stop() }
        _ = try await client(port: port).capabilities()
        #expect(RelayTransport.lastNegotiatedSuite == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))
    }

    /// review-code's probe, as a test. Cancelling the events stream (the app going to the background) closes the
    /// phone's channel at once. The relay learns of it only by writing: the first write after the close is still
    /// accepted, the second fails. Heartbeats every second and a cancel half-way between them: about 1.5 s now; before
    /// this fix the phone first waited for a frame, about 2.5 s.
    @Test func aCancelledEventsStreamClosesItsChannel() async throws {
        let ended = Flag()
        let headers = ["Content-Type": "text/event-stream"]
        let server = RelayServer(keys: [credential: secret], host: "127.0.0.1", port: 0) { _ in
            AsyncThrowingStream { continuation in
                let beat = Task {
                    while !Task.isCancelled {
                        continuation.yield(
                            RelayResponse(
                                status: 200, headers: headers,
                                body: Data("event: heartbeat\ndata: {\"kind\":\"heartbeat\"}\n\n".utf8), more: true))
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                continuation.onTermination = { _ in
                    beat.cancel()
                    ended.set()
                }
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let reading = Task { for try await _ in client(port: port).events() {} }
        // Half-way between two heartbeats.
        try await Task.sleep(for: .milliseconds(1500))
        let cancelled = ContinuousClock.now
        reading.cancel()
        for _ in 0..<80 where ended.when == nil { try await Task.sleep(for: .milliseconds(50)) }
        let seen = try #require(ended.when) - cancelled
        #expect(seen < .seconds(2), "the relay saw the stream end \(seen) after the cancel")
    }

    /// The daemon's own stream through the forwarder: blank lines arrive as their own frames.
    @Test func theForwarderKeepsBlankLines() async throws {
        let script = Script([.events(Data("event: reset\ndata: {}\n\n".utf8))])
        let forward = RelayServer.daemonForwarder(script.baseURL, session: script.session)
        var body = Data()
        for try await frame in forward(RelayRequest(method: "GET", path: "/api/apps/v1/events")) {
            body.append(frame.body)
        }
        #expect(String(decoding: body, as: UTF8.self) == "event: reset\ndata: {}\n\n")
    }
}

/// When something first happened, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var at: ContinuousClock.Instant?
    func set() { lock.withLock { if at == nil { at = .now } } }
    var when: ContinuousClock.Instant? { lock.withLock { at } }
}

/// The secret for a pairing is held only while that pairing is current.
@MainActor @Suite struct RelaySecretTests {
    func link(credential: String) -> String {
        "openrig-remote://pair?v=1&reach=loopback:7433:127.0.0.1&actor=human-example@external&credential=\(credential)&token=orapp_t1"
    }

    func session(credential: String) -> RemoteSession {
        let remote = RemoteSession(
            store: MemoryPairingStore(),
            connect: { _ in RemoteConnector.Outcome(status: .unreachable(detail: nil), client: nil) })
        remote.pair(link: link(credential: credential))
        RelayTransport.secrets.withLock { $0[credential] = RelayLink.newSecret() }
        return remote
    }

    @Test func unpairForgetsTheSecret() {
        let credential = "cred-\(UUID().uuidString)"
        let remote = session(credential: credential)
        remote.unpair()
        #expect(RelayTransport.secrets.withLock { $0[credential] } == nil)
    }

    @Test func pairingAnotherCodeForgetsTheOldSecret() {
        let credential = "cred-\(UUID().uuidString)"
        let remote = session(credential: credential)
        remote.pair(link: link(credential: "cred-\(UUID().uuidString)"))
        #expect(RelayTransport.secrets.withLock { $0[credential] } == nil)
    }
}

@Suite struct RelayReachTests {
    let token = "orapp_" + String(repeating: "ef", count: 32)
    let secret = RelayLink.encode(RelayLink.newSecret())

    func code(secret: String?) throws -> PairingCode {
        try PairingCode(
            reaches: [PairingCode.Reach(kind: .lan, addresses: ["10.0.0.208"], port: 7434)],
            actor: "human-example@external", credentialID: "cred-1", token: token, pairingSecret: secret)
    }

    /// A `lan` reach goes through the relay, keyed by the pairing secret, under the credential id.
    @Test func aLanReachWithASecretGetsARelayClient() throws {
        let endpoint = RemoteEndpoint(kind: .lan, host: "10.0.0.208", port: 7434)
        let client = try #require(
            RemoteConnector.standardClient(allowingLoopback: true)(endpoint, try code(secret: secret)))
        #expect(client.baseURL.scheme == RelayTransport.scheme)
        #expect(client.baseURL.host() == "10.0.0.208")
        #expect(client.baseURL.port == 7434)
        #expect(client.baseURL.user() == "cred-1")
    }

    /// Without a secret, or with one that isn't 256 bits, nothing goes to the Wi-Fi: no plain HTTP, no relay.
    @Test(arguments: [nil, "not-a-secret"])
    func aLanReachWithoutAUsableSecretGetsNothing(secret: String?) throws {
        let endpoint = RemoteEndpoint(kind: .lan, host: "10.0.0.208", port: 7434)
        #expect(RemoteConnector.standardClient(allowingLoopback: true)(endpoint, try code(secret: secret)) == nil)
    }

    @Test func loopbackAndMagicDNSStillUsePlainHTTP() throws {
        let pairing = try code(secret: secret)
        let loopback = RemoteEndpoint(kind: .loopback, host: "127.0.0.1", port: 7433)
        #expect(RemoteConnector.standardClient(allowingLoopback: true)(loopback, pairing)?.baseURL.scheme == "http")
        let name = RemoteEndpoint(kind: .tailnet, host: "mac.tail1234.ts.net", port: 7433)
        #expect(RemoteConnector.standardClient(allowingLoopback: true)(name, pairing)?.baseURL.scheme == "http")
        let ip = RemoteEndpoint(kind: .tailnet, host: "100.64.0.9", port: 7433)
        #expect(RemoteConnector.standardClient(allowingLoopback: true)(ip, pairing) == nil)
    }
}

import Foundation
import Network
import Testing

@testable import RigClient

/// Every listener here binds 127.0.0.1 only: a listener on the Wi-Fi address can make macOS ask the person, on screen.
@Suite(.serialized) struct RelayLinkTests {
    let secret = RelayLink.newSecret()

    @Test func aClientWithTheSecretGetsAnAnswer() async throws {
        let server = try await EchoServer.start(secret: secret)
        defer { server.stop() }
        let channel = RelayChannel(host: "127.0.0.1", port: server.port, secret: secret)
        defer { channel.close() }
        try await channel.open()
        try await channel.send(Data("GET /api/apps/v1/needs-me".utf8))
        #expect(String(decoding: try await channel.receive(), as: UTF8.self) == "GET /api/apps/v1/needs-me")
    }

    /// Without the secret the handshake fails, so the server never reads a byte of the request.
    @Test func aClientWithoutTheSecretGetsNothing() async throws {
        let server = try await EchoServer.start(secret: secret)
        defer { server.stop() }
        let wrong = RelayChannel(host: "127.0.0.1", port: server.port, secret: RelayLink.newSecret())
        defer { wrong.close() }
        await #expect(throws: RelayLinkError.self) { try await wrong.open(timeout: .seconds(3)) }
        #expect(server.received.isEmpty)
    }

    /// What someone listening on the network sees: a recording proxy between the two. Neither the message nor the
    /// secret appears in it.
    @Test func aListenerOnTheWireLearnsNeitherSecretNorContent() async throws {
        let server = try await EchoServer.start(secret: secret)
        defer { server.stop() }
        let tap = try await TapProxy.start(to: server.port)
        defer { tap.stop() }
        let message = Data("answer q-f0af: tabs, explainer, settings-tab".utf8)
        let channel = RelayChannel(host: "127.0.0.1", port: tap.port, secret: secret)
        defer { channel.close() }
        try await channel.open()
        try await channel.send(message)
        #expect(try await channel.receive() == message)

        let wire = tap.recorded
        #expect(wire.count > message.count, "the tap saw the exchange")
        #expect(wire.range(of: message) == nil)
        #expect(wire.range(of: secret) == nil)
        #expect(wire.range(of: Data("q-f0af".utf8)) == nil)
    }

    /// One listener, one key per paired phone, picked by the identity the phone presents (its credential id). A phone
    /// can't borrow another's identity, and a phone no longer listed can't connect.
    @Test func eachPhoneHasItsOwnKey() async throws {
        let other = RelayLink.newSecret()
        let server = try await EchoServer.start(keys: ["cred-a": secret, "cred-b": other])
        defer { server.stop() }
        for (identity, key) in [("cred-a", secret), ("cred-b", other)] {
            let phone = RelayChannel(host: "127.0.0.1", port: server.port, identity: identity, secret: key)
            defer { phone.close() }
            try await phone.open()
            try await phone.send(Data(identity.utf8))
            #expect(try await phone.receive() == Data(identity.utf8))
        }
        let borrowed = RelayChannel(host: "127.0.0.1", port: server.port, identity: "cred-a", secret: other)
        defer { borrowed.close() }
        await #expect(throws: RelayLinkError.self) { try await borrowed.open(timeout: .seconds(3)) }
        let unpaired = RelayChannel(
            host: "127.0.0.1", port: server.port, identity: "cred-c", secret: RelayLink.newSecret())
        defer { unpaired.close() }
        await #expect(throws: RelayLinkError.self) { try await unpaired.open(timeout: .seconds(3)) }
    }

    /// ECDHE_PSK: the handshake adds an ephemeral key exchange to the PSK, so a secret leaked later doesn't decrypt
    /// traffic recorded earlier.
    @Test func theLinkNegotiatesForwardSecrecy() async throws {
        let server = try await EchoServer.start(secret: secret)
        defer { server.stop() }
        let channel = RelayChannel(host: "127.0.0.1", port: server.port, secret: secret)
        defer { channel.close() }
        try await channel.open()
        #expect(channel.negotiatedSuite == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))
    }

    @Test func aFrameOverTheLimitIsRefused() async throws {
        let server = try await EchoServer.start(secret: secret)
        defer { server.stop() }
        let channel = RelayChannel(host: "127.0.0.1", port: server.port, secret: secret)
        defer { channel.close() }
        try await channel.open()
        try await channel.send(Data(repeating: 0x41, count: 16))
        _ = try await channel.receive()
        server.replyWithHeader(UInt32(RelayChannel.maxFrame + 1))
        try await channel.send(Data("next".utf8))
        await #expect(throws: RelayLinkError.tooLarge(RelayChannel.maxFrame + 1)) { _ = try await channel.receive() }
    }
}

/// A TLS-PSK listener on 127.0.0.1 that echoes each frame back, or sends a bare length header when told to.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _received: [Data] = []
    private var bogusHeader: UInt32?
    private(set) var port: UInt16 = 0

    var received: [Data] { lock.withLock { _received } }

    private init(listener: NWListener) { self.listener = listener }

    static func start(secret: Data) async throws -> EchoServer {
        try await start(keys: [RelayLink.defaultIdentity: secret])
    }

    static func start(keys: [String: Data]) async throws -> EchoServer {
        let parameters = RelayLink.serverParameters(keys: keys)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = EchoServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { connection in server.serve(RelayChannel(connection), connection) }
        server.port = try await ready(server.listener)
        return server
    }

    func replyWithHeader(_ length: UInt32) { lock.withLock { bogusHeader = length } }

    private func serve(_ channel: RelayChannel, _ connection: NWConnection) {
        connection.start(queue: .global())
        Task {
            while let message = try? await channel.receive() {
                lock.withLock { _received.append(message) }
                if let header = lock.withLock({ bogusHeader }) {
                    var raw = Data()
                    withUnsafeBytes(of: header.bigEndian) { raw.append(contentsOf: $0) }
                    connection.send(content: raw, completion: .idempotent)
                } else {
                    try? await channel.send(message)
                }
            }
        }
    }

    func stop() { listener.cancel() }
}

/// A plain TCP proxy on 127.0.0.1 that records every byte passing in either direction.
final class TapProxy: @unchecked Sendable {
    private let listener: NWListener
    private let target: UInt16
    private let lock = NSLock()
    private var _recorded = Data()
    private(set) var port: UInt16 = 0

    var recorded: Data { lock.withLock { _recorded } }

    private init(listener: NWListener, target: UInt16) {
        self.listener = listener
        self.target = target
    }

    static func start(to target: UInt16) async throws -> TapProxy {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let tap = TapProxy(listener: try NWListener(using: parameters), target: target)
        tap.listener.newConnectionHandler = { inbound in tap.bridge(inbound) }
        tap.port = try await ready(tap.listener)
        return tap
    }

    private func bridge(_ inbound: NWConnection) {
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
        inbound.start(queue: .global())
        outbound.start(queue: .global())
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                lock.withLock { _recorded.append(data) }
                sink.send(content: data, completion: .idempotent)
            }
            if complete || error != nil {
                sink.cancel()
            } else {
                pump(from: source, to: sink)
            }
        }
    }

    func stop() { listener.cancel() }
}

/// Starts a listener and returns its port once it is ready.
private func ready(_ listener: NWListener) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
        let once = Once()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
            case .failed(let error): once.run { continuation.resume(throwing: error) }
            default: break
            }
        }
        listener.start(queue: .global())
    }
}

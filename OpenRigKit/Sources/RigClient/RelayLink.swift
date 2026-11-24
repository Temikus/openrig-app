import CryptoKit
import Foundation
import Network

/// The phone's link to the Mac's relay: TLS keyed by a pre-shared key, from Network framework on both ends.
///
/// The key is derived from the pairing secret in the QR code, so only a phone that scanned it can finish the
/// handshake. The secret itself never crosses the network, and everything after the handshake is encrypted.
/// URLSession can't speak TLS-PSK, so the phone talks to the relay over `RelayChannel`, not HTTP.
public enum RelayLink {
    /// Names the key in the handshake. Not secret.
    static let identity = "openrig-remote"

    /// A new pairing secret: 256 random bits.
    public static func newSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// TLS parameters keyed by `secret`. The PSK is derived from it, so the raw secret is never the key on the wire.
    public static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = HMAC<SHA256>.authenticationCode(
            for: Data("openrig relay psk v1".utf8), using: SymmetricKey(data: secret))
        let key = Data(psk).withUnsafeBytes { DispatchData(bytes: $0) }
        let name = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, key as __DispatchData, name as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return NWParameters(tls: tls)
    }
}

public enum RelayLinkError: Error, Equatable, Sendable {
    /// The handshake didn't finish: a wrong secret, or nothing listening.
    case notConnected(String)
    case closed
    case tooLarge(Int)
}

/// One connection, as whole messages: each is a 4-byte big-endian length, then that many bytes.
public final class RelayChannel: @unchecked Sendable {
    /// A frame larger than this is refused, so a peer can't make the other end allocate without limit.
    public static let maxFrame = 8 << 20

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openrig.relay.channel")

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public convenience init(host: String, port: UInt16, secret: Data) {
        self.init(
            NWConnection(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                using: RelayLink.parameters(secret: secret)))
    }

    /// Starts the connection and waits for the handshake. A wrong secret fails here.
    public func open(timeout: Duration = .seconds(5)) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: RelayLinkError.notConnected("\(error)")) }
                case .cancelled: once.run { continuation.resume(throwing: RelayLinkError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                once.run { continuation.resume(throwing: RelayLinkError.notConnected("timed out")) }
            }
        }
    }

    public func send(_ message: Data) async throws {
        var frame = Data()
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    public func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxFrame else {
            close()
            throw RelayLinkError.tooLarge(length)
        }
        return length == 0 ? Data() : try await read(length)
    }

    public func close() { connection.cancel() }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: complete ? RelayLinkError.closed : RelayLinkError.notConnected("short read"))
                }
            }
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

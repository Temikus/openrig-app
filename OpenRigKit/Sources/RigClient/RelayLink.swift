import CryptoKit
import Foundation
import Network

/// The phone's link to the Mac's relay: TLS keyed by a pre-shared key, from Network framework on both ends.
///
/// The key is derived from the pairing secret in the QR code, so only a phone that scanned it can finish the
/// handshake. The secret itself never crosses the network, and everything after the handshake is encrypted.
/// URLSession can't speak TLS-PSK, so the phone talks to the relay over `RelayChannel`, not HTTP.
public enum RelayLink {
    /// Names the key in the handshake when there is only one. Not secret; a paired phone uses its credential id.
    public static let defaultIdentity = "openrig-remote"

    /// A new pairing secret: 256 random bits.
    public static func newSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// A phone's side: its identity (its credential id) and the secret from the QR code.
    public static func parameters(identity: String = defaultIdentity, secret: Data) -> NWParameters {
        tls([identity: secret])
    }

    /// The relay's side: one key per paired phone, picked by the identity the phone presents. A phone not listed
    /// can't finish the handshake.
    public static func serverParameters(keys: [String: Data]) -> NWParameters {
        tls(keys)
    }

    /// TLS 1.2 ECDHE_PSK with ChaCha20-Poly1305 (RFC 5489): the PSK authenticates, and an ephemeral ECDH key exchange
    /// gives forward secrecy, so a secret leaked later doesn't decrypt traffic recorded earlier. Each PSK is derived
    /// from its secret, so the raw secret is never the key. (TLS 1.3 with an external PSK fails in Network framework,
    /// -9858 on macOS 27; this suite needs no 1.3.)
    private static func tls(_ keys: [String: Data]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, secret) in keys.sorted(by: { $0.key < $1.key }) {
            let psk = HMAC<SHA256>.authenticationCode(
                for: Data("openrig relay psk v1".utf8), using: SymmetricKey(data: secret))
            let key = Data(psk).withUnsafeBytes { DispatchData(bytes: $0) }
            let name = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, name as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        return NWParameters(tls: tls)
    }
}

public enum RelayLinkError: Error, Equatable, Sendable {
    /// Nothing answered, or the connection broke before the handshake.
    case notConnected(String)
    /// The relay answered but refused the key: a wrong secret, or one the Mac forgot at Unpair.
    case refused(String)
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

    public convenience init(
        host: String, port: UInt16, identity: String = RelayLink.defaultIdentity, secret: Data
    ) {
        self.init(
            NWConnection(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                using: RelayLink.parameters(identity: identity, secret: secret)))
    }

    /// Starts the connection and waits for the handshake. A wrong secret fails here.
    public func open(timeout: Duration = .seconds(5)) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    let failure: RelayLinkError =
                        if case .tls = error { .refused("\(error)") } else { .notConnected("\(error)") }
                    once.run { continuation.resume(throwing: failure) }
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

    /// The cipher suite the handshake settled on, once open.
    var negotiatedSuite: UInt16? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata).rawValue
    }

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

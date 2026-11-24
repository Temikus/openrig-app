import Foundation
import RigModel

/// One address and port from a pairing code's reaches.
public struct RemoteEndpoint: Sendable, Equatable, CustomStringConvertible {
    public var kind: PairingCode.Reach.Kind
    public var host: String
    public var port: Int

    public init(kind: PairingCode.Reach.Kind, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }
    /// Plain HTTP: the daemon on loopback serves no TLS. A relay link (task 8) replaces this for `lan`.
    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    public static func all(in code: PairingCode) -> [RemoteEndpoint] {
        code.reaches.flatMap { reach in
            reach.addresses.map { RemoteEndpoint(kind: reach.kind, host: $0, port: reach.port) }
        }
    }
}

/// Where the phone stands with its Mac.
public enum RemoteStatus: Sendable, Equatable {
    case connected(RemoteEndpoint)
    /// Nothing answered. `detail` is the last error, for the person to read.
    case unreachable(detail: String?)
    /// iOS refused Local Network access, so no Wi-Fi address can answer.
    case localNetworkDenied
    /// 401: the Mac revoked this phone's credential.
    case unpaired
    /// Something answered, but not a daemon with this app's contract.
    case unsupportedDaemon
}

/// Tries each endpoint of a pairing code in order, and says where the phone stands.
public struct RemoteConnector: Sendable {
    public struct Outcome: Sendable {
        public var status: RemoteStatus
        /// The client for the endpoint that answered. Nil unless connected.
        public var client: AppClient?
    }

    /// Nil when this endpoint can't be reached safely, so nothing is sent to it.
    var client: @Sendable (RemoteEndpoint, PairingCode) -> AppClient?
    var localNetworkDenied: @Sendable (RemoteEndpoint) async -> Bool

    public init(
        client: @escaping @Sendable (RemoteEndpoint, PairingCode) -> AppClient? = Self.httpClient,
        localNetworkDenied: @escaping @Sendable (RemoteEndpoint) async -> Bool
    ) {
        self.client = client
        self.localNetworkDenied = localNetworkDenied
    }

    /// Plain HTTP only where the path is already private: this Mac (loopback) or the tailnet (WireGuard). On the
    /// Wi-Fi it would carry the token in clear, so a `lan` endpoint gets no client until an encrypted link exists.
    /// Short per-address timeout: a dead address shouldn't hold up the next one for long.
    public static let httpClient: @Sendable (RemoteEndpoint, PairingCode) -> AppClient? = { endpoint, code in
        guard endpoint.kind != .lan else { return nil }
        return AppClient(baseURL: endpoint.baseURL, token: code.token, actor: code.actor, timeout: 5)
    }

    public static let noEncryptedLink =
        "This Mac is only reachable on Wi-Fi, and this version of the app has no encrypted link for Wi-Fi yet."

    /// The first endpoint that answers wins. Otherwise a revoked credential outranks a stranger on an old address,
    /// which outranks denied Local Network access, which outranks silence.
    public func connect(_ code: PairingCode) async -> Outcome {
        var revoked = false
        var stranger = false
        var lastError: String?
        var firstSilentLan: RemoteEndpoint?
        for endpoint in RemoteEndpoint.all(in: code) {
            guard let app = client(endpoint, code) else {
                lastError = lastError ?? Self.noEncryptedLink
                continue
            }
            do {
                if try await app.capabilities().supportsAnswering {
                    return Outcome(status: .connected(endpoint), client: app)
                }
                stranger = true
            } catch {
                switch error {
                case .unpaired:
                    revoked = true
                case .unsupportedDaemon:
                    stranger = true
                case .unreachable(let message):
                    lastError = message
                    if endpoint.kind == .lan, firstSilentLan == nil { firstSilentLan = endpoint }
                case .refused(let status, let code, _):
                    lastError = "HTTP \(status)" + (code.map { " (\($0))" } ?? "")
                case .decoding(_, let message):
                    stranger = true
                    lastError = message
                }
            }
        }
        if revoked { return Outcome(status: .unpaired) }
        if stranger { return Outcome(status: .unsupportedDaemon) }
        if let firstSilentLan, await localNetworkDenied(firstSilentLan) {
            return Outcome(status: .localNetworkDenied)
        }
        return Outcome(status: .unreachable(detail: lastError))
    }
}

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

    public static let httpClient = plainHTTPClient()

    /// Plain HTTP carries the token in clear, so it goes only where the path is private by construction:
    /// - loopback, when that is this Mac (the simulator). On a phone it is the phone itself.
    /// - a MagicDNS name, which only Tailscale's DNS resolves, so it travels inside WireGuard.
    /// Not a tailnet IP: 100.64.0.0/10 is also carrier-grade NAT, and with Tailscale off it leaves by the default
    /// route. Not `lan`: the Wi-Fi. Those wait for an encrypted link.
    public static func plainHTTPClient(
        allowingLoopback: Bool = loopbackIsThisMac
    ) -> @Sendable (RemoteEndpoint, PairingCode) -> AppClient? {
        { endpoint, code in
            let safe =
                switch endpoint.kind {
                case .loopback: allowingLoopback
                case .tailnet: PairingCode.Reach.Kind.ipv4(endpoint.host) == nil
                case .lan: false
                }
            guard safe else { return nil }
            // Short timeout: a dead address shouldn't hold up the next one for long.
            return AppClient(baseURL: endpoint.baseURL, token: code.token, actor: code.actor, timeout: 5)
        }
    }

    /// True on a Mac and in the iOS simulator, which shares the Mac's network.
    public static let loopbackIsThisMac: Bool = {
        #if os(iOS) && !targetEnvironment(simulator)
            false
        #else
            true
        #endif
    }()

    public static let noSafeAddress =
        "This version of the app can't reach this Mac at its paired addresses without sending its key unencrypted."

    /// The first endpoint that answers wins. Otherwise a revoked credential outranks a stranger on an old address,
    /// which outranks denied Local Network access, which outranks silence.
    public func connect(_ code: PairingCode) async -> Outcome {
        var revoked = false
        var stranger = false
        var lastError: String?
        var firstSilentLan: RemoteEndpoint?
        for endpoint in RemoteEndpoint.all(in: code) {
            guard let app = client(endpoint, code) else {
                lastError = lastError ?? Self.noSafeAddress
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

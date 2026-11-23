import Foundation

/// `GET /healthz`.
public struct DaemonHealth: Decodable, Sendable, Equatable {
    public var status: String
    public var semver: String?
    public var commit: String?
    public var eventLoopHealthy: Bool?
    /// The addresses the daemon listens on. Nil when the daemon doesn't say.
    public var bind: Bind?

    public var isHealthy: Bool { status == "ok" && eventLoopHealthy != false }

    public init(
        status: String, semver: String? = nil, commit: String? = nil, eventLoopHealthy: Bool? = nil, bind: Bind? = nil
    ) {
        self.status = status
        self.semver = semver
        self.commit = commit
        self.eventLoopHealthy = eventLoopHealthy
        self.bind = bind
    }

    public struct Bind: Decodable, Sendable, Equatable {
        /// `explicit` (`rig daemon start --host`) or `default`.
        public var mode: String?
        public var hosts: [String]
        public var tailscaleDetected: Bool?

        public init(mode: String? = nil, hosts: [String], tailscaleDetected: Bool? = nil) {
            self.mode = mode
            self.hosts = hosts
            self.tailscaleDetected = tailscaleDetected
        }

        private enum CodingKeys: String, CodingKey { case mode, hosts, tailscaleDetected }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = c.lenient(String.self, .mode)
            hosts = c.lenient([String].self, .hosts) ?? []
            tailscaleDetected = c.lenient(Bool.self, .tailscaleDetected)
        }

        /// Where a phone can reach this daemon: its tailnet IPv4 or MagicDNS name. Nil while the daemon listens on no
        /// tailnet address, e.g. when Tailscale was off as it started.
        public var tailnetHost: String? { hosts.first(where: PairingCode.isTailnet) }
    }

    private enum CodingKeys: String, CodingKey { case status, semver, commit, eventLoop, bind }
    private enum EventLoopKeys: String, CodingKey { case healthy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(String.self, .status) ?? "unknown"
        semver = c.lenient(String.self, .semver)
        commit = c.lenient(String.self, .commit)
        let loop = try? c.nestedContainer(keyedBy: EventLoopKeys.self, forKey: .eventLoop)
        eventLoopHealthy = loop?.lenient(Bool.self, .healthy)
        bind = c.lenient(Bind.self, .bind)
    }
}

/// Whether the app was built against this daemon's internal HTTP API (PLAN.md risk 3).
public enum DaemonCompatibility: Equatable, Sendable {
    case tested
    case untested(String)
    case unknown
}

extension DaemonHealth {
    /// Tested against rig 0.7.x. Other minor versions may have changed the internal API.
    public static let testedMinor = (major: 0, minor: 7)

    public var compatibility: DaemonCompatibility {
        guard let semver else { return .unknown }
        let parts = semver.split(separator: ".").prefix(2).map { Int($0) }
        guard parts.count == 2, let major = parts[0], let minor = parts[1] else { return .unknown }
        return (major, minor) == Self.testedMinor ? .tested : .untested(semver)
    }
}

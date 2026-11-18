import Foundation

/// `GET /healthz`.
public struct DaemonHealth: Decodable, Sendable, Equatable {
    public var status: String
    public var semver: String?
    public var commit: String?
    public var eventLoopHealthy: Bool?

    public var isHealthy: Bool { status == "ok" && eventLoopHealthy != false }

    public init(status: String, semver: String? = nil, commit: String? = nil, eventLoopHealthy: Bool? = nil) {
        self.status = status
        self.semver = semver
        self.commit = commit
        self.eventLoopHealthy = eventLoopHealthy
    }

    private enum CodingKeys: String, CodingKey { case status, semver, commit, eventLoop }
    private enum EventLoopKeys: String, CodingKey { case healthy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(String.self, .status) ?? "unknown"
        semver = c.lenient(String.self, .semver)
        commit = c.lenient(String.self, .commit)
        let loop = try? c.nestedContainer(keyedBy: EventLoopKeys.self, forKey: .eventLoop)
        eventLoopHealthy = loop?.lenient(Bool.self, .healthy)
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

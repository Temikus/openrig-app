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

import Foundation

/// One row of `GET /api/ps` (same shape as `rig ps --json`).
public struct RigSummary: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var status: RigStatus
    public var nodeCount: Int
    public var runningCount: Int
    public var activeCount: Int
    public var attentionCount: Int
    public var uptime: String?
    public var isArchived: Bool

    public init(
        id: String, name: String, status: RigStatus = .running, nodeCount: Int = 0, runningCount: Int = 0,
        activeCount: Int = 0, attentionCount: Int = 0, uptime: String? = nil, isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.nodeCount = nodeCount
        self.runningCount = runningCount
        self.activeCount = activeCount
        self.attentionCount = attentionCount
        self.uptime = uptime
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case rigId, name, status, nodeCount, runningCount, activeCount, attentionCount, uptime, isArchived
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .rigId)
        name = c.lenient(String.self, .name) ?? id
        status = c.lenient(RigStatus.self, .status) ?? RigStatus(rawValue: "unknown")
        nodeCount = c.lenient(Int.self, .nodeCount) ?? 0
        runningCount = c.lenient(Int.self, .runningCount) ?? 0
        activeCount = c.lenient(Int.self, .activeCount) ?? 0
        attentionCount = c.lenient(Int.self, .attentionCount) ?? 0
        uptime = c.lenient(String.self, .uptime)
        isArchived = c.lenient(Bool.self, .isArchived) ?? false
    }
}

public struct RigStatus: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = RigStatus(rawValue: "running")
    public static let stopped = RigStatus(rawValue: "stopped")
}

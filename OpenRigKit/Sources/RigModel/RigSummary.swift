import Foundation

/// One row of `GET /api/ps` (same shape as `rig ps --json`).
public struct RigSummary: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var status: RigStatus
    /// The daemon's verdict on the rig as a whole; seats stopped on purpose don't count against it.
    public var lifecycle: RigLifecycle
    public var nodeCount: Int
    public var runningCount: Int
    public var activeCount: Int
    public var attentionCount: Int
    public var uptime: String?
    /// Age of the newest snapshot, already formatted by the daemon ("2m ago").
    public var latestSnapshot: String?
    public var isArchived: Bool

    public init(
        id: String, name: String, status: RigStatus = .running, lifecycle: RigLifecycle = .running,
        nodeCount: Int = 0, runningCount: Int = 0, activeCount: Int = 0, attentionCount: Int = 0,
        uptime: String? = nil, latestSnapshot: String? = nil, isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.lifecycle = lifecycle
        self.nodeCount = nodeCount
        self.runningCount = runningCount
        self.activeCount = activeCount
        self.attentionCount = attentionCount
        self.uptime = uptime
        self.latestSnapshot = latestSnapshot
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case rigId, name, status, lifecycleState, nodeCount, runningCount, activeCount, attentionCount, uptime
        case latestSnapshot, isArchived
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .rigId)
        name = c.lenient(String.self, .name) ?? id
        status = c.lenient(RigStatus.self, .status) ?? RigStatus(rawValue: "unknown")
        lifecycle = c.lenient(RigLifecycle.self, .lifecycleState) ?? RigLifecycle(rawValue: "unknown")
        nodeCount = c.lenient(Int.self, .nodeCount) ?? 0
        runningCount = c.lenient(Int.self, .runningCount) ?? 0
        activeCount = c.lenient(Int.self, .activeCount) ?? 0
        attentionCount = c.lenient(Int.self, .attentionCount) ?? 0
        uptime = c.lenient(String.self, .uptime)
        latestSnapshot = c.lenient(String.self, .latestSnapshot)
        isArchived = c.lenient(Bool.self, .isArchived) ?? false
    }
}

/// Counts of running sessions: `partial` means some but not all.
public struct RigStatus: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = RigStatus(rawValue: "running")
    public static let partial = RigStatus(rawValue: "partial")
    public static let stopped = RigStatus(rawValue: "stopped")
}

/// `lifecycleState` from `rig ps`, folded from each seat's state.
public struct RigLifecycle: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = RigLifecycle(rawValue: "running")
    /// Some seats are down and none was stopped on purpose.
    public static let degraded = RigLifecycle(rawValue: "degraded")
    /// Nothing is running, but at least one seat can be restored.
    public static let recoverable = RigLifecycle(rawValue: "recoverable")
    public static let stopped = RigLifecycle(rawValue: "stopped")
    public static let attentionRequired = RigLifecycle(rawValue: "attention_required")
}

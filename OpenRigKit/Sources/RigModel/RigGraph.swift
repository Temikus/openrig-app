import Foundation

/// `GET /api/rigs/:id/graph`, reshaped from React Flow nodes into pods, seats and spec edges.
/// The daemon sends every position as (0, 0); layout is the app's job.
public struct RigGraph: Decodable, Sendable, Equatable {
    public var pods: [Pod]
    public var seats: [Seat]
    public var edges: [SpecEdge]

    public init(pods: [Pod] = [], seats: [Seat] = [], edges: [SpecEdge] = []) {
        self.pods = pods
        self.seats = seats
        self.edges = edges
    }

    /// Seats in daemon order. Seats whose pod is missing from the payload are not returned for any pod.
    public func seats(in podID: Pod.ID) -> [Seat] {
        seats.filter { $0.podID == podID }
    }

    private enum CodingKeys: String, CodingKey { case nodes, edges }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = try c.decode([Lossy<RawNode>].self, forKey: .nodes).compactMap(\.value)
        var pods: [Pod] = []
        var seats: [Seat] = []
        for node in nodes {
            switch node.type {
            case "podGroup": pods.append(Pod(node))
            case "rigNode": seats.append(Seat(node))
            default: continue
            }
        }
        self.pods = pods
        self.seats = seats
        self.edges = (c.lenient([Lossy<SpecEdge>].self, .edges) ?? []).compactMap(\.value)
    }
}

public struct Pod: Sendable, Identifiable, Hashable {
    public var id: String
    public var logicalId: String
    public var label: String

    public init(id: String, logicalId: String, label: String) {
        self.id = id
        self.logicalId = logicalId
        self.label = label
    }

    init(_ node: RawNode) {
        let logical = node.data.logicalId ?? node.id
        self.init(id: node.id, logicalId: logical, label: node.data.podLabel ?? logical)
    }
}

public struct Seat: Sendable, Identifiable, Hashable {
    public var id: String
    public var podID: Pod.ID?
    /// Spec id, e.g. `orch.lead`.
    public var logicalId: String
    /// tmux session and `rig send` target, e.g. `orch-lead@denkeeper`.
    public var sessionName: String?
    public var kind: NodeKind
    public var runtime: String?
    public var model: String?
    public var status: SeatStatus
    public var activity: AgentActivity?
    public var tmuxPane: String?
    public var needsAttention: Bool
    public var heldReason: String?
    public var contextUsedPercent: Int?
    public var currentQItems: [QItemRef]
    public var work: WorkCounts

    /// Short name the UI shows, e.g. `orch-lead`.
    public var displayName: String {
        if let sessionName, let at = sessionName.firstIndex(of: "@") {
            return String(sessionName[..<at])
        }
        return logicalId.replacingOccurrences(of: ".", with: "-")
    }

    public init(
        id: String, podID: Pod.ID? = nil, logicalId: String, sessionName: String? = nil,
        kind: NodeKind = .agent, runtime: String? = nil, model: String? = nil,
        status: SeatStatus = .running, activity: AgentActivity? = nil, tmuxPane: String? = nil,
        needsAttention: Bool = false, heldReason: String? = nil, contextUsedPercent: Int? = nil,
        currentQItems: [QItemRef] = [], work: WorkCounts = WorkCounts()
    ) {
        self.id = id
        self.podID = podID
        self.logicalId = logicalId
        self.sessionName = sessionName
        self.kind = kind
        self.runtime = runtime
        self.model = model
        self.status = status
        self.activity = activity
        self.tmuxPane = tmuxPane
        self.needsAttention = needsAttention
        self.heldReason = heldReason
        self.contextUsedPercent = contextUsedPercent
        self.currentQItems = currentQItems
        self.work = work
    }

    init(_ node: RawNode) {
        let d = node.data
        self.init(
            id: node.id,
            podID: node.parentId,
            logicalId: d.logicalId ?? node.id,
            sessionName: d.canonicalSessionName ?? d.binding?.tmuxSession,
            kind: d.nodeKind ?? .agent,
            runtime: d.runtime,
            model: d.model,
            status: d.status ?? SeatStatus(rawValue: "unknown"),
            activity: d.agentActivity,
            tmuxPane: d.binding?.tmuxPane,
            needsAttention: d.needsAttention ?? false,
            heldReason: d.heldReason,
            contextUsedPercent: d.contextUsedPercentage,
            currentQItems: (d.currentQitems ?? []).compactMap(\.value),
            work: WorkCounts(
                pending: d.pendingWorkCount ?? 0,
                inProgress: d.inProgressWorkCount ?? 0,
                blocked: d.blockedWorkCount ?? 0
            )
        )
    }
}

public struct WorkCounts: Sendable, Hashable {
    public var pending: Int
    public var inProgress: Int
    public var blocked: Int

    public init(pending: Int = 0, inProgress: Int = 0, blocked: Int = 0) {
        self.pending = pending
        self.inProgress = inProgress
        self.blocked = blocked
    }
}

/// An in-progress qitem the daemon attaches to a seat (`currentQitems`).
public struct QItemRef: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var bodyExcerpt: String
    public var tier: String?

    public init(id: String, bodyExcerpt: String = "", tier: String? = nil) {
        self.id = id
        self.bodyExcerpt = bodyExcerpt
        self.tier = tier
    }

    private enum CodingKeys: String, CodingKey { case qitemId, bodyExcerpt, tier }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .qitemId)
        bodyExcerpt = c.lenient(String.self, .bodyExcerpt) ?? ""
        tier = c.lenient(String.self, .tier)
    }
}

public struct AgentActivity: Decodable, Sendable, Hashable {
    public var state: ActivityState
    public var reason: String?
    /// True when the daemon's evidence is old; treat `state` as a guess.
    public var stale: Bool

    public init(state: ActivityState, reason: String? = nil, stale: Bool = false) {
        self.state = state
        self.reason = reason
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey { case state, reason, stale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(ActivityState.self, .state) ?? .unknown
        reason = c.lenient(String.self, .reason)
        stale = c.lenient(Bool.self, .stale) ?? false
    }
}

public struct SpecEdge: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var source: Seat.ID
    public var target: Seat.ID
    public var kind: EdgeKind

    public init(id: String, source: Seat.ID, target: Seat.ID, kind: EdgeKind) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, source, target, label }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        kind = c.lenient(EdgeKind.self, .label) ?? EdgeKind(rawValue: "")
        id = c.lenient(String.self, .id) ?? "\(source)-\(kind.rawValue)-\(target)"
    }
}

// MARK: - Open value sets

public struct EdgeKind: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let delegatesTo = EdgeKind(rawValue: "delegates_to")
    public static let canObserve = EdgeKind(rawValue: "can_observe")
}

public struct ActivityState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = ActivityState(rawValue: "running")
    public static let needsInput = ActivityState(rawValue: "needs_input")
    public static let idle = ActivityState(rawValue: "idle")
    public static let unknown = ActivityState(rawValue: "unknown")
}

public struct SeatStatus: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = SeatStatus(rawValue: "running")
}

public struct NodeKind: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let agent = NodeKind(rawValue: "agent")
    public static let infrastructure = NodeKind(rawValue: "infrastructure")
}

// MARK: - Wire shapes

/// Decodes to nil instead of throwing, so one malformed array element does not drop the array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct RawNode: Decodable {
    let id: String
    let type: String
    let parentId: String?
    let data: RawNodeData

    private enum CodingKeys: String, CodingKey { case id, type, parentId, data }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lenient(String.self, .type) ?? ""
        parentId = c.lenient(String.self, .parentId)
        data = c.lenient(RawNodeData.self, .data) ?? RawNodeData()
    }
}

struct RawNodeData: Decodable {
    struct Binding: Decodable {
        var tmuxSession: String?
        var tmuxPane: String?
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tmuxSession = c.lenient(String.self, .tmuxSession)
            tmuxPane = c.lenient(String.self, .tmuxPane)
        }
        private enum CodingKeys: String, CodingKey { case tmuxSession, tmuxPane }
    }

    var logicalId: String?
    var podLabel: String?
    var canonicalSessionName: String?
    var nodeKind: NodeKind?
    var runtime: String?
    var model: String?
    var status: SeatStatus?
    var agentActivity: AgentActivity?
    var binding: Binding?
    var needsAttention: Bool?
    var heldReason: String?
    var contextUsedPercentage: Int?
    var currentQitems: [Lossy<QItemRef>]?
    var pendingWorkCount: Int?
    var inProgressWorkCount: Int?
    var blockedWorkCount: Int?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case logicalId, podLabel, canonicalSessionName, nodeKind, runtime, model, status, agentActivity
        case binding, needsAttention, heldReason, contextUsedPercentage, currentQitems
        case pendingWorkCount, inProgressWorkCount, blockedWorkCount
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logicalId = c.lenient(String.self, .logicalId)
        podLabel = c.lenient(String.self, .podLabel)
        canonicalSessionName = c.lenient(String.self, .canonicalSessionName)
        nodeKind = c.lenient(NodeKind.self, .nodeKind)
        runtime = c.lenient(String.self, .runtime)
        model = c.lenient(String.self, .model)
        status = c.lenient(SeatStatus.self, .status)
        agentActivity = c.lenient(AgentActivity.self, .agentActivity)
        binding = c.lenient(Binding.self, .binding)
        needsAttention = c.lenient(Bool.self, .needsAttention)
        heldReason = c.lenient(String.self, .heldReason)
        contextUsedPercentage = c.lenient(Double.self, .contextUsedPercentage).map { Int($0.rounded()) }
        currentQitems = c.lenient([Lossy<QItemRef>].self, .currentQitems)
        pendingWorkCount = c.lenient(Int.self, .pendingWorkCount)
        inProgressWorkCount = c.lenient(Int.self, .inProgressWorkCount)
        blockedWorkCount = c.lenient(Int.self, .blockedWorkCount)
    }
}

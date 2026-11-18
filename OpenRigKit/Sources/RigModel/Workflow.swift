import Foundation

/// One `GET /api/workflow/list` row, cut down to what the next-hop wire needs.
public struct WorkflowInstance: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: String
    public var boundRig: String?
    /// Open packets and the step each one is at. Parallel steps give several.
    public var frontier: [FrontierPacket]
    /// The spec as it was when the instance started; later edits don't apply to it.
    public var spec: WorkflowSpec

    public init(
        id: String, status: String = "active", boundRig: String? = nil, frontier: [FrontierPacket],
        spec: WorkflowSpec
    ) {
        self.id = id
        self.status = status
        self.boundRig = boundRig
        self.frontier = frontier
        self.spec = spec
    }

    public struct FrontierPacket: Decodable, Sendable, Equatable {
        public var qitemID: String
        public var stepID: String

        public init(qitemID: String, stepID: String) {
            self.qitemID = qitemID
            self.stepID = stepID
        }

        private enum CodingKeys: String, CodingKey { case packetId, stepId }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            qitemID = try c.decode(String.self, forKey: .packetId)
            stepID = try c.decode(String.self, forKey: .stepId)
        }
    }

    private enum CodingKeys: String, CodingKey { case instanceId, status, boundRig, frontierPackets, startedSpec }
    private enum StartedKeys: String, CodingKey { case spec }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .instanceId)
        status = c.lenient(String.self, .status) ?? "unknown"
        boundRig = c.lenient(String.self, .boundRig)
        frontier = (c.lenient([Lossy<FrontierPacket>].self, .frontierPackets) ?? []).compactMap(\.value)
        spec = try c.nestedContainer(keyedBy: StartedKeys.self, forKey: .startedSpec).decode(
            WorkflowSpec.self, forKey: .spec)
    }
}

/// The parts of a workflow spec that decide who works next.
public struct WorkflowSpec: Decodable, Sendable, Equatable {
    public var steps: [Step]
    /// Role name to its preferred seats (`preferred_targets`), in order.
    public var roles: [String: [String]]

    public init(steps: [Step], roles: [String: [String]]) {
        self.steps = steps
        self.roles = roles
    }

    public struct Step: Decodable, Sendable, Equatable {
        public var id: String
        public var role: String
        /// Runtime the step's owner must run, e.g. `claude-code`.
        public var harness: String?
        /// `require` or `forbid`, or nil.
        public var nextMode: String?
        public var suggestedRoles: [String]

        public init(
            id: String, role: String, harness: String? = nil, nextMode: String? = nil, suggestedRoles: [String] = []
        ) {
            self.id = id
            self.role = role
            self.harness = harness
            self.nextMode = nextMode
            self.suggestedRoles = suggestedRoles
        }

        private enum CodingKeys: String, CodingKey {
            case id, harness
            case role = "actor_role"
            case nextHop = "next_hop"
        }
        private enum NextHopKeys: String, CodingKey {
            case mode
            case suggestedRoles = "suggested_roles"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            role = c.lenient(String.self, .role) ?? ""
            harness = c.lenient(String.self, .harness)
            let next = try? c.nestedContainer(keyedBy: NextHopKeys.self, forKey: .nextHop)
            nextMode = next?.lenient(String.self, .mode)
            suggestedRoles = next?.lenient([String].self, .suggestedRoles) ?? []
        }
    }

    private struct Role: Decodable {
        var preferredTargets: [String]?
        private enum CodingKeys: String, CodingKey { case preferredTargets = "preferred_targets" }
    }

    private enum CodingKeys: String, CodingKey { case steps, roles }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = (c.lenient([Lossy<Step>].self, .steps) ?? []).compactMap(\.value)
        roles = (c.lenient([String: Role].self, .roles) ?? [:]).mapValues { $0.preferredTargets ?? [] }
    }
}

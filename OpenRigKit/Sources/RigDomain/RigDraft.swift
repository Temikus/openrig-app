import Foundation
import Yams

/// A new rig being built from a library template: its name and seats as edited in New Rig, and the rig.yaml they make.
///
/// The YAML keeps every key of the template it doesn't edit (startup files, env, services…). Only `name`, each
/// seat's runtime, model and effort, and the seats themselves change. A saved spec lives in its own folder, so
/// `local:` agent refs, which are relative to the template's folder, become absolute `path:` refs; the template's
/// other files (culture, guidance) are copied beside it, where its relative paths still find them.
public struct RigDraft: Sendable, Equatable {
    public struct Seat: Sendable, Equatable, Identifiable {
        public var pod: String
        public var member: String
        /// The template's agent_ref: the seat's role.
        public var agentRef: String?
        public var runtime: String
        /// Nil leaves it out: the runtime or role default.
        public var model: String?
        /// Nil leaves it out: the runtime default.
        public var effort: String?
        /// The template's runtime. A terminal seat has no agent behind it, so it stays a terminal.
        public let templateRuntime: String
        /// The agent spec profile the seat uses; OpenRig's default is "default".
        public var profile: String? = nil
        /// Extra startup text for this seat only (New Rig's seat detail).
        public var notes = ""
        /// Skills for this seat only, on top of its role's.
        public var addedSkills: [SkillChoice] = []

        /// Added in New Rig rather than read from the template.
        public var isAdded = false

        /// A seat added in New Rig, its role an agent spec folder.
        public static func added(pod: String, member: String, role: String, runtime: String) -> Seat {
            Seat(
                pod: pod, member: member, agentRef: "path:" + role, runtime: runtime, model: nil, effort: nil,
                templateRuntime: "", profile: "default", isAdded: true)
        }

        /// The logical id, as edges and sessions name it: "dev.build".
        public var id: String { "\(pod).\(member)" }
        public var isTerminal: Bool { templateRuntime == Runtime.terminal }
    }

    /// An edge between two seats, by logical id ("orch.lead" → "dev.build").
    public struct Edge: Sendable, Hashable {
        public var kind: String
        public var from: String
        public var to: String

        public init(kind: String, from: String, to: String) {
            self.kind = kind
            self.from = from
            self.to = to
        }
    }

    public var name: String
    public var seats: [Seat]
    /// Edges for added seats. The template's own edges stay in its text.
    public private(set) var addedEdges: [Edge] = []
    /// The template's own text and folder.
    public let template: String
    public let folder: String
    /// The project folder, written as every seat's `cwd`. A relative cwd resolves against the folder the spec is
    /// saved in (`~/.openrig/specs/<name>`), and `rig up --cwd` lasts one run, so a later `rig up <name>` would
    /// start the seats there. Nil keeps the template's own cwd.
    public var cwd: String?

    public enum Failure: Error, Equatable {
        case notARigSpec
    }

    /// `folder` is the directory holding the template's rig.yaml, which its `local:` refs are relative to.
    public init(template yaml: String, folder: String) throws {
        guard let root = try Yams.compose(yaml: yaml)?.mapping else { throw Failure.notARigSpec }
        template = yaml
        self.folder = folder
        name = root["name"]?.string ?? ""
        seats = (root["pods"]?.sequence ?? []).flatMap { pod -> [Seat] in
            guard let podID = pod["id"]?.string else { return [] }
            return (pod["members"]?.sequence ?? []).compactMap { member in
                guard let id = member["id"]?.string else { return nil }
                let runtime = member["runtime"]?.string ?? ""
                return Seat(
                    pod: podID, member: id, agentRef: member["agent_ref"]?.string, runtime: runtime,
                    model: member["model"]?.string, effort: member["effort"]?.string, templateRuntime: runtime,
                    profile: member["profile"]?.string)
            }
        }
    }

    /// A rig with no seats yet, for "Blank rig". Its spec starts from OpenRig's empty shape.
    public static func blank() -> RigDraft {
        try! RigDraft(template: "version: \"0.2\"\nname: blank\npods: []\nedges: []\n", folder: "/")
    }

    /// The template's seats in order; one removed from `seats` is gone from the YAML, with its edges.
    public var templateSeats: [Seat] { (try? RigDraft(template: template, folder: folder).seats) ?? [] }

    /// The template's edges, every one by logical id, the pod's own and the rig's.
    public var templateEdges: [Edge] {
        guard let root = (try? Yams.compose(yaml: template))?.mapping else { return [] }
        func edge(_ node: Node, pod: String?) -> Edge? {
            guard let kind = node["kind"]?.string, let from = node["from"]?.string, let to = node["to"]?.string
            else { return nil }
            let qualified = { (end: String) in pod.map { "\($0).\(end)" } ?? end }
            return Edge(kind: kind, from: qualified(from), to: qualified(to))
        }
        let pods = (root["pods"]?.sequence ?? []).flatMap { pod in
            (pod["edges"]?.sequence ?? []).compactMap { edge($0, pod: pod["id"]?.string) }
        }
        return pods + (root["edges"]?.sequence ?? []).compactMap { edge($0, pod: nil) }
    }

    /// Every pod the rig has now, in order: the template's that still have a seat, then new ones.
    public var pods: [String] {
        var pods: [String] = []
        for seat in seats where !pods.contains(seat.pod) { pods.append(seat.pod) }
        return pods
    }

    /// Adds a seat at the end of its pod (a new pod goes last), with its edges.
    public mutating func add(_ seat: Seat, edges: [Edge] = []) {
        var seat = seat
        seat.isAdded = true
        let at = seats.lastIndex { $0.pod == seat.pod }.map { $0 + 1 } ?? seats.endIndex
        seats.insert(seat, at: at)
        for edge in edges where !addedEdges.contains(edge) { addedEdges.append(edge) }
    }

    public mutating func remove(_ id: Seat.ID) {
        seats.removeAll { $0.id == id }
        addedEdges.removeAll { $0.from == id || $0.to == id }
    }

    /// Member ids in use, the template's included, so an added seat never takes a removed seat's place in the
    /// template's text.
    public var takenMembers: Set<String> { Set((seats + templateSeats).map(\.member)) }

    /// The rig.yaml these edits make.
    public func yaml() throws -> String {
        guard var root = try Yams.compose(yaml: template)?.mapping else { throw Failure.notARigSpec }
        root["name"] = Node(name)
        let kept = Dictionary(seats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keptPods: Set<String> = []
        var pods: [Node] = []
        for case .mapping(var pod) in root["pods"]?.sequence ?? [] {
            guard let podID = pod["id"]?.string else { continue }
            var ids: Set<String> = []
            var members: [Node] = []
            for case .mapping(let member) in pod["members"]?.sequence ?? [] {
                guard let id = member["id"]?.string, let seat = kept["\(podID).\(id)"] else { continue }
                ids.insert(id)
                members.append(.mapping(edited(member, as: seat)))
            }
            members += added(in: podID)
            guard !members.isEmpty else { continue }
            keptPods.insert(podID)
            pod["members"] = Node(members)
            var edges: [Node] = (pod["edges"]?.sequence ?? []).filter { edge in
                [edge["from"]?.string, edge["to"]?.string].allSatisfy { $0.map(ids.contains) ?? true }
            }
            edges += addedEdges(in: podID)
            if pod["edges"] != nil || !edges.isEmpty { pod["edges"] = Node(edges) }
            pods.append(.mapping(pod))
        }
        // Pods only added seats are in: OpenRig requires a label.
        for podID in self.pods where !keptPods.contains(podID) {
            keptPods.insert(podID)
            pods.append(
                .mapping(
                    Node.Mapping([
                        (Node("id"), Node(podID)),
                        (Node("label"), Node(podID.prefix(1).uppercased() + podID.dropFirst())),
                        (Node("members"), Node(added(in: podID))), (Node("edges"), Node(addedEdges(in: podID))),
                    ])))
        }
        root["pods"] = Node(pods)
        // Rig-level edges name seats as "pod.member", or a whole pod.
        if let edges = root["edges"]?.sequence {
            root["edges"] = Node(
                edges.filter { edge in
                    [edge["from"]?.string, edge["to"]?.string].allSatisfy { end in
                        guard let end else { return true }
                        let pod = String(end.prefix { $0 != "." })
                        return end.contains(".") ? kept[end] != nil : keptPods.contains(pod)
                    }
                })
        }
        let across = addedEdges.filter { pod(of: $0.from) != pod(of: $0.to) }
        if !across.isEmpty { root["edges"] = Node(Array(root["edges"]?.sequence ?? []) + across.map(node)) }
        return try Yams.serialize(node: .mapping(root), width: -1)
    }

    private func added(in pod: String) -> [Node] {
        seats.filter { $0.isAdded && $0.pod == pod }.map { seat in
            let base = Node.Mapping([
                (Node("id"), Node(seat.member)), (Node("agent_ref"), Node(seat.agentRef ?? "")),
                (Node("profile"), Node(seat.profile ?? "default")),
            ])
            return .mapping(edited(base, as: seat))
        }
    }

    private func addedEdges(in pod: String) -> [Node] {
        addedEdges.filter { self.pod(of: $0.from) == pod && self.pod(of: $0.to) == pod }.map { edge in
            node(Edge(kind: edge.kind, from: member(of: edge.from), to: member(of: edge.to)))
        }
    }

    private func node(_ edge: Edge) -> Node {
        .mapping(
            Node.Mapping([
                (Node("kind"), Node(edge.kind)), (Node("from"), Node(edge.from)), (Node("to"), Node(edge.to)),
            ]))
    }

    private func pod(of id: String) -> String { String(id.prefix { $0 != "." }) }
    private func member(of id: String) -> String { String(id.drop { $0 != "." }.dropFirst()) }

    private func edited(_ member: Node.Mapping, as seat: Seat) -> Node.Mapping {
        var member = member
        if let cwd { member.set("cwd", Self.cwd(member["cwd"]?.string, in: cwd), after: "profile") }
        if seat.runtime == Runtime.terminal {
            // The schema's terminal triple; the keys only an agent seat may carry go.
            member.set("agent_ref", "builtin:terminal", after: "id")
            member.set("runtime", Runtime.terminal, after: "agent_ref")
            member.set("profile", "none", after: "runtime")
            for key in ["model", "effort", "role", "permission_policy", "starter_ref", "session_source"] {
                member[key] = nil
            }
            return member
        }
        member.set("runtime", seat.runtime, after: "agent_ref")
        member.set("model", seat.model, after: "runtime")
        member.set("effort", seat.effort, after: seat.model == nil ? "runtime" : "model")
        if let ref = seat.agentRef, let absolute = Self.absolute(ref, in: folder) {
            member.set("agent_ref", absolute, after: "id")
        }
        let added = seatStartupFiles(seat)
        if !added.isEmpty {
            var startup = member["startup"]?.mapping ?? Node.Mapping([])
            startup["files"] = Node((startup["files"]?.sequence.map(Array.init) ?? []) + added)
            member["startup"] = .mapping(startup)
        }
        return member
    }

    /// A member's cwd for the project: a relative one ("docs", "../shared") resolved against it, as OpenRig resolves
    /// it against `--cwd`; an absolute or `~` one as written.
    static func cwd(_ authored: String?, in project: String) -> String {
        guard let authored, !authored.isEmpty else { return project }
        if authored.hasPrefix("/") || authored.hasPrefix("~") { return authored }
        let path = URL(filePath: project).appending(path: authored).standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `local:<relative>` as `path:<absolute>`, resolved against `folder`. Other refs are left alone (nil).
    static func absolute(_ ref: String, in folder: String) -> String? {
        guard ref.hasPrefix("local:") else { return nil }
        let relative = String(ref.dropFirst("local:".count))
        return "path:" + URL(filePath: folder).appending(path: relative).standardizedFileURL.path(percentEncoded: false)
    }

    /// The agent spec folder a seat's role points to, when it is a file reference.
    public func agentFolder(_ seat: Seat) -> URL? {
        guard let ref = seat.agentRef else { return nil }
        if ref.hasPrefix("path:") { return URL(filePath: String(ref.dropFirst(5))) }
        return Self.absolute(ref, in: folder).map { URL(filePath: String($0.dropFirst(5))) }
    }

    /// The role's name for a seat: its agent spec's `name:`, else the folder's name. "terminal" for a terminal seat.
    public func roleName(_ seat: Seat) -> String {
        if seat.agentRef == "builtin:terminal" { return Runtime.terminal }
        guard let folder = agentFolder(seat) else { return seat.agentRef ?? "" }
        return agentSpec(seat)?["name"]?.string ?? folder.lastPathComponent
    }

    /// What a seat's role sets when the rig spec names no model: its profile's `preferences`, else the agent spec's
    /// `defaults`, in OpenRig's order (profile-resolver).
    public func roleDefault(_ seat: Seat) -> RoleDefault {
        guard let spec = agentSpec(seat) else { return RoleDefault() }
        let preferences = spec["profiles"]?[seat.profile ?? "default"]?["preferences"]
        func value(_ key: String) -> String? {
            [preferences?[key]?.string, spec["defaults"]?[key]?.string]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        return RoleDefault(model: value("model"), runtime: value("runtime") ?? "claude-code")
    }

    private func agentSpec(_ seat: Seat) -> Node? {
        guard let folder = agentFolder(seat) else { return nil }
        for file in ["agent.yaml", "agent.yml"] {
            if let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8),
                let spec = try? Yams.compose(yaml: text)
            {
                return spec
            }
        }
        return nil
    }
}

/// A role's own model, and the runtime it was chosen for.
public struct RoleDefault: Sendable, Equatable {
    public var model: String?
    public var runtime: String

    public init(model: String? = nil, runtime: String = "claude-code") {
        self.model = model
        self.runtime = runtime
    }

    /// The role's model on a seat running `runtime`: a Codex model means nothing to Claude Code, so a seat moved to
    /// another runtime shows that runtime's default.
    public func model(on runtime: String) -> String? { runtime == self.runtime ? model : nil }
}

/// The runtimes a rig spec seat can name (the daemon's adapters).
public enum Runtime {
    public static let terminal = "terminal"
    public static let all = ["claude-code", "codex", "pi", "omp", "stub", terminal]

    public static func label(_ runtime: String) -> String {
        switch runtime {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case "pi": "Pi"
        case "omp": "OMP"
        case "stub": "Stub (test)"
        case terminal: "Terminal"
        default: runtime
        }
    }
}

extension Node.Mapping {
    /// Sets `key`, or removes it for nil. A new key goes after `anchor` when that is present, so a seat reads
    /// id, agent_ref, runtime, model, effort as people write it.
    mutating func set(_ key: String, _ value: String?, after anchor: String) {
        guard let value else {
            self[key] = nil
            return
        }
        if self[key] != nil {
            self[key] = Node(value)
            return
        }
        var pairs = Array(self).map { ($0.key, $0.value) }
        let at = pairs.firstIndex { $0.0.string == anchor }.map { $0 + 1 } ?? pairs.endIndex
        pairs.insert((Node(key), Node(value)), at: at)
        self = Node.Mapping(pairs, tag, style, mark)
    }
}

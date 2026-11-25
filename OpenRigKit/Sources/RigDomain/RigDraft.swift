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

        /// The logical id, as edges and sessions name it: "dev.build".
        public var id: String { "\(pod).\(member)" }
        public var isTerminal: Bool { templateRuntime == Runtime.terminal }
    }

    public var name: String
    public var seats: [Seat]
    /// The template's own text and folder.
    public let template: String
    public let folder: String

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
                    model: member["model"]?.string, effort: member["effort"]?.string, templateRuntime: runtime)
            }
        }
    }

    /// The template's seats in order; one removed from `seats` is gone from the YAML, with its edges.
    public var templateSeats: [Seat] { (try? RigDraft(template: template, folder: folder).seats) ?? [] }

    public mutating func remove(_ id: Seat.ID) {
        seats.removeAll { $0.id == id }
    }

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
            guard !members.isEmpty else { continue }
            keptPods.insert(podID)
            pod["members"] = Node(members)
            if let edges = pod["edges"]?.sequence {
                pod["edges"] = Node(
                    edges.filter { edge in
                        [edge["from"]?.string, edge["to"]?.string].allSatisfy { $0.map(ids.contains) ?? true }
                    })
            }
            pods.append(.mapping(pod))
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
        return try Yams.serialize(node: .mapping(root), width: -1)
    }

    private func edited(_ member: Node.Mapping, as seat: Seat) -> Node.Mapping {
        var member = member
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
        return member
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
        for file in ["agent.yaml", "agent.yml"] {
            if let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8),
                let name = (try? Yams.compose(yaml: text))??["name"]?.string
            {
                return name
            }
        }
        return folder.lastPathComponent
    }
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

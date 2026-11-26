import Foundation
import Yams

/// A role a seat can take: an agent spec OpenRig knows, with a `default` profile for a new seat to use.
public struct Role: Sendable, Equatable, Identifiable {
    public var name: String
    public var summary: String
    /// The agent spec's folder, as an added seat's `path:` ref names it.
    public var folder: String

    public var id: String { folder }

    public init(name: String, summary: String, folder: String) {
        self.name = name
        self.summary = summary
        self.folder = folder
    }

    /// The role in `agent.yaml` at `file`, or nil when it has no `default` profile (OpenRig's `shared` resources,
    /// for one) or isn't readable.
    public static func load(agentSpec file: URL, summary: String? = nil) -> Role? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let spec = try? Yams.compose(yaml: text), spec["profiles"]?["default"] != nil
        else { return nil }
        let folder = Self.plain(file.deletingLastPathComponent().resolvingSymlinksInPath().path(percentEncoded: false))
        let name = spec["name"]?.string ?? URL(filePath: folder).lastPathComponent
        return Role(name: name, summary: summary ?? spec["description"]?.string ?? "", folder: folder)
    }

    /// A folder path without its trailing "/", so a role read from its file and one named by a ref compare equal.
    public static func plain(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Edges for an added seat, the way the library's templates connect its role. OpenRig doesn't derive edges (a spec
/// lists each one), so New Rig learns them: when a template has an edge from a seat of role A to a seat of role B,
/// a new seat of role A gets that edge to every seat of role B in the rig, and the same the other way round.
public struct EdgeRules: Sendable, Equatable {
    public struct Rule: Sendable, Hashable {
        public var from: String
        public var kind: String
        public var to: String
    }

    public var rules: [Rule]
    /// Each role's usual member id and pod in the templates ("build" in "dev"), most common first.
    public var names: [String: (member: String, pod: String)]

    public static func == (a: EdgeRules, b: EdgeRules) -> Bool { a.rules == b.rules }

    public init(learningFrom templates: [RigDraft]) {
        var rules: [Rule] = []
        var counts: [String: [String: Int]] = [:]
        for draft in templates {
            let roles = Dictionary(
                draft.seats.compactMap { seat in draft.roleFolder(seat).map { (seat.id, $0) } },
                uniquingKeysWith: { first, _ in first })
            for seat in draft.seats {
                guard let role = roles[seat.id] else { continue }
                counts[role, default: [:]]["\(seat.pod).\(seat.member)", default: 0] += 1
            }
            for edge in draft.templateEdges {
                guard let from = roles[edge.from], let to = roles[edge.to] else { continue }
                let rule = Rule(from: from, kind: edge.kind, to: to)
                if !rules.contains(rule) { rules.append(rule) }
            }
        }
        self.rules = rules
        names = counts.compactMapValues { ids in
            // The most common; ties go to the alphabetically first, so the suggestion is stable.
            guard let id = ids.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            return (member: parts[1], pod: parts[0])
        }
    }

    /// The edges `seat` (not yet in `draft`) gets to and from the seats already there.
    public func edges(for seat: RigDraft.Seat, in draft: RigDraft) -> [RigDraft.Edge] {
        guard let role = draft.roleFolder(seat) else { return [] }
        var edges: [RigDraft.Edge] = []
        for other in draft.seats where other.id != seat.id {
            guard let theirs = draft.roleFolder(other) else { continue }
            for rule in rules {
                let edge: RigDraft.Edge? =
                    if rule.from == role, rule.to == theirs {
                        RigDraft.Edge(kind: rule.kind, from: seat.id, to: other.id)
                    } else if rule.to == role, rule.from == theirs {
                        RigDraft.Edge(kind: rule.kind, from: other.id, to: seat.id)
                    } else { nil }
                if let edge, !edges.contains(edge) { edges.append(edge) }
            }
        }
        return edges
    }

    /// A member id and pod for a new seat of `role`: the templates' usual ones, numbered when the id is taken
    /// ("build" → "build2"; "r1" → "r2").
    public func suggestion(for role: Role, taken: Set<String>) -> (member: String, pod: String) {
        let usual = names[role.folder]
        let base = usual?.member ?? SeatName.from(role.name)
        return (SeatName.unique(base, taken: taken), usual?.pod ?? "dev")
    }
}

public enum SeatName {
    /// "Independent reviewer" → "independent-reviewer": what a member id may hold.
    public static func from(_ text: String) -> String {
        let id = text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return id.isEmpty ? "seat" : id
    }

    /// `base`, or its stem numbered from 2 (or from its own number) until it is free.
    public static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        let stem = String(base.reversed().drop { $0.isNumber }.reversed())
        let start = Int(base.dropFirst(stem.count)).map { $0 + 1 } ?? 2
        return (start...).lazy.map { "\(stem.isEmpty ? "seat" : stem)\($0)" }.first { !taken.contains($0) }!
    }

    /// What's wrong with a typed member id, or nil. OpenRig's ids: letters, digits, `-` and `_`.
    public static func problem(_ id: String, taken: Set<String>) -> String? {
        if id.isEmpty { return "Name the seat." }
        if id.wholeMatch(of: /[a-z0-9][a-z0-9_-]*/) == nil {
            return "A seat name uses lower-case letters, digits, - and _."
        }
        if taken.contains(id) { return "This rig already has a seat named \(id)." }
        return nil
    }

    public static func podProblem(_ pod: String) -> String? {
        if pod.isEmpty { return "Name the pod." }
        if pod.wholeMatch(of: /[a-z0-9][a-z0-9_-]*/) == nil {
            return "A pod name uses lower-case letters, digits, - and _."
        }
        return nil
    }
}

extension RigDraft {
    /// The agent spec folder a seat's role is, with symlinks resolved (nvm and Homebrew paths often go through one),
    /// so a template's `local:` ref and the library's path to the same role match.
    public func roleFolder(_ seat: Seat) -> String? {
        agentFolder(seat).map { Role.plain($0.resolvingSymlinksInPath().path(percentEncoded: false)) }
    }
}

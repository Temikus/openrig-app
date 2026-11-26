import Foundation
import Yams

/// A new role, drafted by the kernel's lead from one line and edited in New Rig before it is saved.
///
/// The lead writes three files into a folder the app owns (`RoleDraft.Files`), then `READY`. The app reads them as
/// a suggestion, not as a spec: it takes the name, summary, guidance, skills and defaults, checks each, and writes
/// the agent spec itself (`files(shared:available:)`), in the shape OpenRig's built-in roles use.
public struct RoleDraft: Sendable, Equatable {
    public struct Skill: Sendable, Equatable, Identifiable {
        public var id: String
        /// The drafter's reason, shown beside it.
        public var why: String
        /// Ticked: it goes in the role's profile.
        public var on: Bool

        public init(id: String, why: String, on: Bool = true) {
            self.id = id
            self.why = why
            self.on = on
        }
    }

    /// The agent spec's `name`: its id in the library, and the folder it is saved in.
    public var name: String
    /// The agent spec's `description`, shown in the role library.
    public var summary: String
    /// `guidance/role.md`: what the seat reads when it starts.
    public var guidance: String
    public var skills: [Skill]
    public var runtime: String
    public var model: String?
    public var effort: String?

    public init(
        name: String, summary: String, guidance: String, skills: [Skill] = [], runtime: String = "claude-code",
        model: String? = nil, effort: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.guidance = guidance
        self.skills = skills
        self.runtime = runtime
        self.model = model
        self.effort = effort
    }

    /// The files the drafter writes, relative to the folder it is given.
    public enum Files {
        public static let agent = "agent.yaml"
        public static let guidance = "guidance/role.md"
        public static let skills = "skills.json"
        /// Written last, once the others are complete.
        public static let ready = "READY"
    }

    public enum Failure: Error, Equatable {
        case missing(String)
        case unreadable(String, String)

        public var message: String {
            switch self {
            case .missing(let file): "The draft has no \(file)."
            case .unreadable(let file, let why): "The draft's \(file) can't be read: \(why)"
            }
        }
    }

    /// The runtimes a role can default to: the agent runtimes, not a test stub or a plain terminal.
    public static let runtimes = Runtime.all.filter { $0 != "stub" && $0 != Runtime.terminal }

    // MARK: Reading what came back

    /// What the drafter wrote in `folder`. Anything missing or malformed is a failure; values that are only wrong
    /// (a bad name, an unknown skill) come through, for `problems` and `unknownSkills` to name.
    public static func read(from folder: URL) throws(Failure) -> RoleDraft {
        func text(_ file: String) throws(Failure) -> String {
            guard let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8) else {
                throw .missing(file)
            }
            return text
        }
        let agentText = try text(Files.agent)
        guard let spec = (try? Yams.compose(yaml: agentText)) ?? nil, spec.mapping != nil else {
            throw .unreadable(Files.agent, "it isn't a YAML mapping.")
        }
        let guidance = try text(Files.guidance)
        let skillsText = try text(Files.skills)
        struct Suggested: Decodable {
            var id: String
            var why: String?
        }
        guard let suggested = try? JSONDecoder().decode([Suggested].self, from: Data(skillsText.utf8)) else {
            throw .unreadable(Files.skills, "it isn't a JSON list of {\"id\", \"why\"}.")
        }
        func value(_ node: Node?) -> String? {
            node?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let runtime = value(spec["defaults"]?["runtime"]) ?? "claude-code"
        var seen: Set<String> = []
        return RoleDraft(
            name: value(spec["name"]) ?? "",
            summary: value(spec["description"]) ?? "",
            guidance: guidance,
            skills: suggested.compactMap { skill in
                let id = skill.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                return Skill(id: id, why: skill.why?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            },
            runtime: runtimes.contains(runtime) ? runtime : "claude-code",
            model: value(spec["defaults"]?["model"]),
            effort: value(spec["defaults"]?["effort"]))
    }

    // MARK: Checking

    /// What stops a save, in the order the person would fix it. `roles` are the names already in the library; `taken`
    /// the folder names already in the person's spec library (a rig spec there takes a name too).
    public func problems(roles: Set<String>, taken: Set<String>) -> [String] {
        var problems: [String] = []
        if let problem = Self.nameProblem(name, roles: roles, taken: taken) { problems.append(problem) }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Add a summary.") }
        if guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Add the guidance.") }
        return problems
    }

    public static func nameProblem(_ name: String, roles: Set<String>, taken: Set<String>) -> String? {
        if name.isEmpty { return "Name the role." }
        if name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) == nil {
            return "A role name uses lower-case letters, digits and -, such as migration-reviewer."
        }
        if roles.contains(name) { return "A role named \(name) already exists. Pick another name." }
        if taken.contains(name) { return "Your spec library already has a folder named \(name). Pick another name." }
        return nil
    }

    /// Suggested skills OpenRig can't find: they are shown, flagged, and never written.
    public func unknownSkills(available: [SkillChoice]) -> [String] {
        let known = Set(available.map(\.id))
        return skills.map(\.id).filter { !known.contains($0) }
    }

    // MARK: Writing

    /// The saved role's files, by path in its folder: agent.yaml, guidance/role.md, and a copy of each ticked skill
    /// that isn't in the shared pool (a project's or the catalog's), declared as the role's own resource so it travels
    /// with the role. `shared` is OpenRig's shared agent spec folder, which the built-in roles import.
    public func files(shared: URL, available: [SkillChoice]) -> [String: SeatFile] {
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ticked = skills.filter(\.on).compactMap { byID[$0.id] }
        let own = ticked.filter { $0.source != .openRig }
        var files: [String: SeatFile] = [
            Files.agent: .text(agentSpec(shared: shared, skills: ticked.map(\.id), own: own.map(\.id))),
            Files.guidance: .text(guidance.hasSuffix("\n") ? guidance : guidance + "\n"),
        ]
        for skill in own { files["skills/\(skill.id)"] = .folder(skill.folder) }
        return files
    }

    /// Writes the role's files into `folder`, made if needed: the folder `rig specs add` then copies to the library.
    public func write(into folder: URL, shared: URL, available: [SkillChoice]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SeatFile.write(files(shared: shared, available: available), into: folder)
    }

    func agentSpec(shared: URL, skills: [String], own: [String]) -> String {
        var defaults: [(Node, Node)] = [(Node("runtime"), Node(runtime))]
        if let model { defaults.append((Node("model"), Node(model))) }
        if let effort { defaults.append((Node("effort"), Node(effort))) }
        let list = { (items: [String]) in Node(items.map { Node($0) }, Tag(.seq), .flow) }
        let fromShared = { (ids: [String]) in list(ids.map { "shared:\($0)" }) }
        var resources: [(Node, Node)] = [
            (
                Node("guidance"),
                Node([.mapping(Node.Mapping([(Node("id"), Node("role")), (Node("path"), Node(Files.guidance))]))])
            )
        ]
        if !own.isEmpty {
            resources.append(
                (
                    Node("skills"),
                    Node(
                        own.map {
                            .mapping(Node.Mapping([(Node("id"), Node($0)), (Node("path"), Node("skills/\($0)"))]))
                        })
                ))
        }
        let spec = Node.Mapping([
            (Node("name"), Node(name)),
            (Node("version"), Node("1.0", Tag(.str), .doubleQuoted)),
            (Node("description"), Node(summary.trimmingCharacters(in: .whitespacesAndNewlines))),
            (Node("defaults"), .mapping(Node.Mapping(defaults))),
            (
                Node("imports"),
                Node([.mapping(Node.Mapping([(Node("ref"), Node("path:" + shared.path(percentEncoded: false)))]))])
            ),
            (
                Node("profiles"),
                .mapping(
                    Node.Mapping([
                        (
                            Node("default"),
                            .mapping(
                                Node.Mapping([
                                    (
                                        Node("uses"),
                                        .mapping(
                                            Node.Mapping([
                                                (Node("skills"), list(skills)),
                                                (Node("guidance"), list([])),
                                                (Node("subagents"), list([])),
                                                (Node("plugins"), fromShared(["openrig-core"])),
                                                (
                                                    Node("runtime_resources"),
                                                    fromShared([
                                                        "claude-default-settings", "claude-default-mcp",
                                                        "codex-default-config", "claude-activity-hooks",
                                                    ])
                                                ),
                                            ]))
                                    )
                                ]))
                        )
                    ]))
            ),
            (Node("resources"), .mapping(Node.Mapping(resources))),
            (
                Node("startup"),
                .mapping(
                    Node.Mapping([
                        (
                            Node("files"),
                            Node([
                                .mapping(
                                    Node.Mapping([
                                        (Node("path"), Node(Files.guidance)), (Node("orientation"), Node("role")),
                                        (Node("delivery_hint"), Node("send_text")),
                                        (Node("required"), Node("true", Tag(.bool))),
                                    ]))
                            ])
                        ),
                        (Node("actions"), list([])),
                    ]))
            ),
        ])
        return (try? Yams.serialize(node: .mapping(spec), width: -1)) ?? ""
    }

    // MARK: The ask

    /// The queue row's body for the kernel's lead: the person's line, the project, the exact files and format, and
    /// the skills that exist, so its suggestions can be real ones.
    public static func ask(line: String, project: String, folder: String, skills: [SkillChoice]) -> String {
        let pool = skills.map { "- \($0.id) (\($0.source.rawValue))" + ($0.summary.map { ": \($0)" } ?? "") }
        return """
            # Draft a new role for New Rig

            The person is building a rig in OpenRig.app and no existing role fits. Draft one agent role from their \
            line. The app reads your files, shows every field for them to edit, and saves the role itself. Write \
            files only in the folder below, and change nothing else.

            The person's line: \(line)
            Project folder (read it for context, don't change it): \(project)
            Write into: \(folder)

            ## Files to write, in this order

            1. `\(Files.agent)`: an OpenRig agent spec with just these keys:
               ```yaml
               name: migration-reviewer        # lower-case letters, digits and -
               description: One line for the role library.
               defaults:
                 runtime: claude-code          # one of: \(runtimes.joined(separator: ", "))
                 model: opus                   # optional; leave out for the runtime's default
                 effort: high                  # optional
               ```
            2. `\(Files.guidance)`: the role's guidance in Markdown, what the seat reads when it starts. Say what it \
            does, what it checks or makes, how it reports and to whom, and what it doesn't do.
            3. `\(Files.skills)`: a JSON list of skills the role should have, each with why, such as \
            `[{"id": "systematic-debugging", "why": "Finds the cause before proposing a fix"}]`. Use only ids from \
            this list; `[]` is fine:
            \(pool.isEmpty ? "- (none found)" : pool.joined(separator: "\n"))
            4. `\(Files.ready)`: empty. Write it last: the app reads the draft when it appears.

            Then close this row as done (closure reason no-follow-on). If you can't draft it, close it with the \
            reason in the resolution instead of writing READY.
            """
    }

    /// The skills a new role can name: OpenRig's shared pool (by id, as the built-in roles do), the project's
    /// `.claude/skills` and `.agents/skills`, and the managed catalog. The first of a name wins.
    public static func availableSkills(shared: URL, project: URL?, catalog: URL?) -> [SkillChoice] {
        var found: [SkillChoice] = []
        if let spec = RigDraft.agentSpec(in: shared) {
            for skill in spec["resources"]?["skills"]?.sequence ?? [] {
                guard let path = skill["path"]?.string,
                    let choice = RigDraft.skill(at: shared.appending(path: path).standardizedFileURL, source: .openRig)
                else { continue }
                found.append(choice)
            }
        }
        if let project {
            for dir in [".claude/skills", ".agents/skills"] {
                found += RigDraft.skills(in: project.appending(path: dir), source: .project)
            }
        }
        if let catalog { found += RigDraft.skills(in: catalog, source: .library) }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.id).inserted }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The queue row asking the kernel's lead for a draft: which one is open, and when it has been answered.
public struct RoleAsk: Sendable, Equatable {
    /// The open ask, if any.
    public private(set) var row: String?

    public init(row: String? = nil) { self.row = row }

    /// The row `rig queue create --json` made, from its output; nil when it says no id.
    public static func created(from output: String) -> RoleAsk? {
        struct Created: Decodable { var qitemId: String }
        return (try? JSONDecoder().decode(Created.self, from: Data(output.utf8))).map { RoleAsk(row: $0.qitemId) }
    }

    /// The row to close as canceled, once: Cancel, Draft Again and the sheet going away all withdraw it, and only
    /// the first of them closes it.
    public mutating func withdraw() -> String? {
        defer { row = nil }
        return row
    }

    /// The ask is answered (a draft came back, or the lead closed it): nothing is left to withdraw.
    public mutating func answered() { row = nil }

    /// A row in this state is no longer being worked on: done, handed off, or anything else that isn't open.
    public static func isClosed(state: String) -> Bool { !["pending", "in-progress", "blocked"].contains(state) }
}

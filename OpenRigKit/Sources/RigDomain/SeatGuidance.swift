import Foundation
import Yams

/// What a seat reads when it starts, layer by layer, and the skills it gets: the New Rig seat detail.
///
/// The layers follow OpenRig's own assembly (`resolveStartup` in the daemon, and the startup guide's layering model):
/// the role (agent spec, then its profile), culture (OpenRig's default, then the rig's `culture_file`), the rig's,
/// the pod's and the member's startup files, then OpenRig's own start files. The project's instruction file comes
/// first: the harness reads it when it starts, with OpenRig's merged layers inside it, before any file is sent.
public struct GuidanceLayer: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case project, role, culture, rig, pod, seat, notes, openRig
    }

    public var kind: Kind
    public var name: String
    /// One line: what the layer is.
    public var what: String
    public var files: [GuidanceFile]

    public var id: Kind { kind }
    /// Only seat notes are edited here; every other layer is a file other seats or rigs share.
    public var isEditable: Bool { kind == .notes }
}

/// One startup file, where it comes from and how it reaches the seat.
public struct GuidanceFile: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        /// Typed into the seat's terminal once it is ready (`send_text`).
        case sent
        /// Merged as a managed block into the named instruction file (`guidance_merge`).
        case merged(into: String)
        /// Installed into the seat's skills (`skill_install`).
        case skill
        /// The project's own file, read by the harness.
        case readByHarness
    }

    /// As the spec names it.
    public var path: String
    public var url: URL
    public var delivery: Delivery

    public init(path: String, url: URL, delivery: Delivery) {
        self.path = path
        self.url = url
        self.delivery = delivery
    }

    public var deliveryLabel: String {
        switch delivery {
        case .sent: "sent when the seat starts"
        case .merged(let file): "merged into \(file)"
        case .skill: "installed as a skill"
        case .readByHarness: "read by the runtime itself"
        }
    }
}

/// A skill the person can add to one seat.
public struct SkillChoice: Sendable, Equatable, Hashable, Identifiable {
    public enum Source: String, Sendable {
        /// An agent spec's skill pool the role imports (OpenRig's shared skills, for the built-in roles).
        case openRig = "OpenRig"
        case project = "Project"
        /// The managed skill catalog `rig skill loadout` reads (`~/.openrig/skills`).
        case library = "Your skills"
    }

    /// The folder's name, which is the name OpenRig installs it under.
    public var id: String
    /// The folder holding its SKILL.md.
    public var folder: URL
    public var source: Source
    /// SKILL.md's `description`.
    public var summary: String?

    public init(id: String, folder: URL, source: Source, summary: String? = nil) {
        self.id = id
        self.folder = folder
        self.source = source
        self.summary = summary
    }
}

/// A file the spec folder needs beside rig.yaml for a seat's notes and added skills.
public enum SeatFile: Sendable, Equatable {
    case text(String)
    /// A folder to copy whole.
    case folder(URL)
}

extension RigDraft {
    /// Where a seat's notes are written, beside rig.yaml.
    public static func notesPath(_ seat: Seat) -> String { "seat-notes/\(seat.id).md" }
    /// Where an added skill is copied, beside rig.yaml: one folder per seat, so two seats' skills with the same name
    /// (a project's and the catalog's) don't overwrite each other. OpenRig installs it under the folder's name.
    public static func skillPath(_ id: String, for seat: Seat) -> String { "seat-skills/\(seat.id)/\(id)" }

    /// The member startup files a seat's notes and added skills add. Notes are sent, not merged: a merged block
    /// lands in the instruction file every seat in that folder reads, and these are for this seat only.
    func seatStartupFiles(_ seat: Seat) -> [Node] {
        var files: [Node] = []
        if !seat.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            files.append(Self.startupFile(Self.notesPath(seat), hint: "send_text"))
        }
        for skill in seat.addedSkills {
            files.append(Self.startupFile(Self.skillPath(skill.id, for: seat) + "/SKILL.md", hint: "skill_install"))
        }
        return files
    }

    private static func startupFile(_ path: String, hint: String) -> Node {
        .mapping(
            Node.Mapping([
                (Node("path"), Node(path)), (Node("delivery_hint"), Node(hint)),
                (Node("required"), Node("true", Tag(.bool))),
            ]))
    }

    /// The files beside rig.yaml that the seats' notes and added skills need, by path relative to the spec folder.
    public var seatFiles: [String: SeatFile] {
        var files: [String: SeatFile] = [:]
        for seat in seats where seat.runtime != Runtime.terminal {
            let notes = seat.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { files[Self.notesPath(seat)] = .text(notes + "\n") }
            for skill in seat.addedSkills { files[Self.skillPath(skill.id, for: seat)] = .folder(skill.folder) }
        }
        return files
    }

    /// Writes `seatFiles` into a spec folder. Earlier seat notes and skills there are replaced, so a removed one goes.
    public func writeSeatFiles(into folder: URL) throws {
        let fm = FileManager.default
        for dir in ["seat-notes", "seat-skills"] { try? fm.removeItem(at: folder.appending(path: dir)) }
        for (path, file) in seatFiles {
            let target = folder.appending(path: path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch file {
            case .text(let text): try text.write(to: target, atomically: true, encoding: .utf8)
            case .folder(let source):
                // A linked skill folder (a project's .claude/skills often links elsewhere) is copied as its target,
                // and a linked SKILL.md as its text: a relative link would dangle beside rig.yaml.
                let real = source.resolvingSymlinksInPath()
                try fm.copyItem(at: real, to: target)
                let skill = target.appending(path: "SKILL.md")
                if (try? fm.destinationOfSymbolicLink(atPath: skill.path)) != nil {
                    let text = try Data(contentsOf: real.appending(path: "SKILL.md").resolvingSymlinksInPath())
                    try fm.removeItem(at: skill)
                    try text.write(to: skill)
                }
            }
        }
    }

    // MARK: Layers

    /// The seat's guidance, top to bottom. `project` is the folder the seat works in; `assets` is OpenRig's
    /// `daemon/assets` folder, for its default culture and start files (left out when unknown).
    public func guidance(for seat: Seat, project: URL?, assets: URL?) -> [GuidanceLayer] {
        guard let root = try? Yams.compose(yaml: template)?.mapping else { return [] }
        let specFolder = URL(filePath: folder)
        let pod = (root["pods"]?.sequence ?? []).first { $0["id"]?.string == seat.pod }
        let member = (pod?["members"]?.sequence ?? []).first { $0["id"]?.string == seat.member }
        let instructions = instructionFile(for: seat.runtime, root: root)
        func resolve(_ node: Node?, in base: URL) -> [GuidanceFile] {
            (node?["files"]?.sequence ?? []).compactMap { file in
                guard let path = file["path"]?.string else { return nil }
                let hint = file["delivery_hint"]?.string ?? "auto"
                return GuidanceFile(
                    path: path, url: base.appending(path: path).standardizedFileURL,
                    delivery: Self.delivery(
                        hint, path: path, orientation: file["orientation"]?.string, into: instructions))
            }
        }
        var layers: [GuidanceLayer] = []

        let names = seat.runtime == "claude-code" ? ["CLAUDE.md", "CLAUDE.local.md"] : ["AGENTS.md"]
        let found =
            (project.map { dir in
                names.filter { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
                    .map { GuidanceFile(path: $0, url: dir.appending(path: $0), delivery: .readByHarness) }
            }) ?? []
        layers.append(
            GuidanceLayer(
                kind: .project, name: "Project",
                what: found.isEmpty
                    ? "No \(instructions) in the project yet: OpenRig creates it for its merged layers"
                    : "The repository's own instructions, with OpenRig's merged layers added",
                files: found))

        let isTerminal = seat.runtime == Runtime.terminal || seat.agentRef == "builtin:terminal"
        if !isTerminal, let agent = agentFolder(seat), let spec = Self.agentSpec(in: agent) {
            let profile = spec["profiles"]?[seat.profile ?? "default"]
            let files = resolve(spec["startup"], in: agent) + resolve(profile?["startup"], in: agent)
            layers.append(
                GuidanceLayer(
                    kind: .role, name: "Role",
                    what: "\(roleName(seat)): " + (spec["description"]?.string ?? "the role's own guidance"),
                    files: files))
        }

        var culture: [GuidanceFile] = []
        if let assets {
            let url = assets.appending(path: "guidance/CULTURE-default.md")
            culture.append(GuidanceFile(path: "CULTURE-default.md", url: url, delivery: .merged(into: instructions)))
        }
        if let path = root["culture_file"]?.string {
            culture.append(
                GuidanceFile(
                    path: path, url: specFolder.appending(path: path).standardizedFileURL,
                    delivery: Self.delivery("auto", path: path, orientation: nil, into: instructions)))
        }
        layers.append(
            GuidanceLayer(
                kind: .culture, name: "Culture",
                what: root["culture_file"] == nil
                    ? "OpenRig's default culture, shared by every seat"
                    : "OpenRig's default culture, then this rig's, shared by every seat",
                files: culture))

        let rigFiles = resolve(root["startup"], in: specFolder)
        if !rigFiles.isEmpty {
            layers.append(
                GuidanceLayer(
                    kind: .rig, name: "Rig", what: "Startup files for every seat in this rig", files: rigFiles))
        }
        let podFiles = resolve(pod?["startup"], in: specFolder)
        if !podFiles.isEmpty {
            layers.append(
                GuidanceLayer(
                    kind: .pod, name: "Pod", what: "Startup files for every seat in the \(seat.pod) pod",
                    files: podFiles))
        }
        let memberFiles = resolve(member?["startup"], in: specFolder)
        if !memberFiles.isEmpty {
            layers.append(
                GuidanceLayer(
                    kind: .seat, name: "Seat startup", what: "The template's own files for \(seat.member)",
                    files: memberFiles))
        }
        if !isTerminal {
            layers.append(
                GuidanceLayer(
                    kind: .notes, name: "Seat notes", what: "Extra instructions for \(seat.member) only",
                    files: [
                        GuidanceFile(
                            path: Self.notesPath(seat), url: specFolder.appending(path: Self.notesPath(seat)),
                            delivery: .sent)
                    ]))
        }
        if let assets, !isTerminal {
            let start = [
                ("openrig-start.md", "guidance/openrig-start.md"),
                ("openrig-context-entry.md", "guidance/openrig-context-entry.md"),
                ("openrig-onboarding-01.md", "onboarding/01-world-and-purpose.md"),
                ("openrig-onboarding-02.md", "onboarding/02-self-and-competent-action.md"),
            ]
            layers.append(
                GuidanceLayer(
                    kind: .openRig, name: "OpenRig",
                    what: "How to find its identity, skills and help, and on a fresh start, the onboarding",
                    files: start.map { GuidanceFile(path: $0.0, url: assets.appending(path: $0.1), delivery: .sent) }))
        }
        return layers
    }

    /// The file a seat's merged layers go into: the rig's `managed_blocks` choice for Claude (default CLAUDE.md),
    /// AGENTS.md for the others.
    private func instructionFile(for runtime: String, root: Node.Mapping) -> String {
        guard runtime == "claude-code" else { return "AGENTS.md" }
        return root["managed_blocks"]?["claude-code"]?.string ?? "CLAUDE.md"
    }

    /// A startup file's delivery, `auto` resolved as OpenRig does: a role file is sent, a SKILL.md installed, any
    /// other Markdown merged, and anything else sent.
    static func delivery(_ hint: String, path: String, orientation: String?, into file: String) -> GuidanceFile.Delivery
    {
        switch hint {
        case "send_text": return .sent
        case "guidance_merge": return .merged(into: file)
        case "skill_install": return .skill
        default:
            if orientation == "role" || path == "guidance/role.md" || path.hasSuffix("/guidance/role.md") {
                return .sent
            }
            if path.hasSuffix("SKILL.md") { return .skill }
            return path.hasSuffix(".md") ? .merged(into: file) : .sent
        }
    }

    /// OpenRig's `daemon/assets` folder, from a spec that ships with it (`…/daemon/specs/…`).
    public static func assets(besideShippedSpec path: String) -> URL? {
        guard let range = path.range(of: "/daemon/specs/") else { return nil }
        return URL(filePath: String(path[..<range.lowerBound]) + "/daemon/assets")
    }

    // MARK: Skills

    /// The skills the seat's role gives it: its profile's `uses.skills`, without an import prefix (`shared:`).
    public func roleSkills(_ seat: Seat) -> [String] {
        guard let agent = agentFolder(seat), let spec = Self.agentSpec(in: agent) else { return [] }
        let profile = seat.profile ?? "default"
        let uses = spec["profiles"]?[profile]?["uses"]?["skills"]
        let ids = uses?.sequence?.compactMap(\.string) ?? uses?.string.map { [$0] } ?? []
        return ids.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
    }

    /// Skills OpenRig can install for this seat, leaving out the role's own: the pools of the role's agent spec and
    /// the specs it imports, the project's `.claude/skills` and `.agents/skills`, then the managed catalog.
    public func skillChoices(for seat: Seat, project: URL?, catalog: URL?) -> [SkillChoice] {
        var found: [SkillChoice] = []
        if let agent = agentFolder(seat), let spec = Self.agentSpec(in: agent) {
            var specs = [(agent, spec)]
            for ref in (spec["imports"]?.sequence ?? []).compactMap({ $0["ref"]?.string }) {
                guard let folder = Self.folder(ofRef: ref, from: agent), let imported = Self.agentSpec(in: folder)
                else { continue }
                specs.append((folder, imported))
            }
            for (folder, spec) in specs {
                for skill in spec["resources"]?["skills"]?.sequence ?? [] {
                    guard let path = skill["path"]?.string else { continue }
                    let dir = folder.appending(path: path).standardizedFileURL
                    if let choice = Self.skill(at: dir, source: .openRig) { found.append(choice) }
                }
            }
        }
        if let project {
            for dir in [".claude/skills", ".agents/skills"] {
                found += Self.skills(in: project.appending(path: dir), source: .project)
            }
        }
        if let catalog { found += Self.skills(in: catalog, source: .library) }
        var seen = Set(roleSkills(seat))
        return found.filter { seen.insert($0.id).inserted }
    }

    static func agentSpec(in folder: URL) -> Node? {
        for file in ["agent.yaml", "agent.yml"] {
            if let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8),
                let node = try? Yams.compose(yaml: text)
            {
                return node
            }
        }
        return nil
    }

    /// An import's folder: `local:` relative to the importing spec's folder, `path:` absolute.
    static func folder(ofRef ref: String, from base: URL) -> URL? {
        if ref.hasPrefix("path:") { return URL(filePath: String(ref.dropFirst(5))) }
        if ref.hasPrefix("local:") { return base.appending(path: String(ref.dropFirst(6))).standardizedFileURL }
        return nil
    }

    /// Each folder in `dir` that holds a SKILL.md.
    static func skills(in dir: URL, source: SkillChoice.Source) -> [SkillChoice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().compactMap { skill(at: dir.appending(path: $0), source: source) }
    }

    static func skill(at dir: URL, source: SkillChoice.Source) -> SkillChoice? {
        guard let text = try? String(contentsOf: dir.appending(path: "SKILL.md"), encoding: .utf8) else { return nil }
        return SkillChoice(
            id: dir.lastPathComponent, folder: dir, source: source, summary: frontmatter(text)["description"])
    }

    /// A SKILL.md's frontmatter, as strings.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
            let map = (try? Yams.compose(yaml: lines[1..<end].joined(separator: "\n")))??.mapping
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in map { if let k = key.string, let v = value.string { out[k] = v } }
        return out
    }
}

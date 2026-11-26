import Foundation
import Testing
import Yams

@testable import RigDomain

/// A copy of the shipped layout: a template under daemon/specs/rigs, its roles under daemon/specs/agents importing
/// the shared skill pool, OpenRig's assets, and a project with its own CLAUDE.md and a skill.
@Suite struct SeatGuidanceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "seatguidance-\(UUID().uuidString)")
    var specs: URL { root.appending(path: "cli/daemon/specs") }
    var templateFolder: URL { specs.appending(path: "rigs/launch/starter") }
    var project: URL { root.appending(path: "project") }

    static let template = """
        version: "0.2"
        name: starter
        culture_file: CULTURE.md
        pods:
          - id: dev
            label: Project
            startup:
              files:
                - path: guidance/pod.md
            members:
              - id: build
                agent_ref: "local:../../../agents/development/implementer"
                runtime: claude-code
                profile: default
                cwd: "."
                startup:
                  files:
                    - path: guidance/lead-first-move.md
                      delivery_hint: send_text
                      required: true
              - id: review
                agent_ref: "local:../../../agents/development/implementer"
                runtime: codex
                profile: default
                cwd: "."
        edges: []
        """

    init() throws {
        func write(_ path: String, _ text: String, in base: URL) throws {
            let url = base.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("rig.yaml", Self.template, in: templateFolder)
        try write("CULTURE.md", "# Culture\n", in: templateFolder)
        try write("guidance/pod.md", "pod\n", in: templateFolder)
        try write("guidance/lead-first-move.md", "first\n", in: templateFolder)
        try write(
            "agents/development/implementer/agent.yaml",
            """
            name: implementer
            description: Implementation agent
            imports:
              - ref: local:../../shared
            profiles:
              default:
                uses:
                  skills: [systematic-debugging, shared:development-team]
            startup:
              files:
                - path: guidance/role.md
                  orientation: role
                  delivery_hint: send_text
            """, in: specs)
        try write("agents/development/implementer/guidance/role.md", "# Role\n", in: specs)
        try write(
            "agents/shared/agent.yaml",
            """
            name: shared
            resources:
              skills:
                - id: test-driven-development
                  path: skills/process/test-driven-development
                - id: systematic-debugging
                  path: skills/process/systematic-debugging
                - id: development-team
                  path: skills/pods/development-team
            """, in: specs)
        for skill in ["process/test-driven-development", "process/systematic-debugging", "pods/development-team"] {
            try write(
                "agents/shared/skills/\(skill)/SKILL.md", "---\nname: x\ndescription: Does \(skill)\n---\n# Skill\n",
                in: specs)
        }
        try write("agents/shared/skills/process/test-driven-development/references/a.md", "ref\n", in: specs)
        try write("cli/daemon/assets/guidance/CULTURE-default.md", "default\n", in: root)
        try write("CLAUDE.md", "# Project\n", in: project)
        try write(".claude/skills/house-style/SKILL.md", "---\ndescription: House style\n---\n", in: project)
    }

    func draft() throws -> RigDraft { try RigDraft(template: Self.template, folder: templateFolder.path) }
    var assets: URL? { RigDraft.assets(besideShippedSpec: templateFolder.appending(path: "rig.yaml").path) }

    @Test func layersFollowOpenRigsStartupOrder() throws {
        let draft = try draft()
        let build = try #require(draft.seats.first { $0.member == "build" })
        let layers = draft.guidance(for: build, project: project, assets: assets)
        #expect(layers.map(\.kind) == [.project, .role, .culture, .pod, .seat, .notes, .openRig])
        #expect(layers.filter(\.isEditable).map(\.kind) == [.notes])
        let byKind = Dictionary(uniqueKeysWithValues: layers.map { ($0.kind, $0) })
        #expect(byKind[.project]?.files.map(\.path) == ["CLAUDE.md"])
        #expect(byKind[.role]?.files.map(\.delivery) == [.sent], "the role file is sent, so pod-mates keep their own")
        #expect(byKind[.role]?.what == "implementer: Implementation agent")
        #expect(
            byKind[.culture]?.files.map(\.path) == ["CULTURE-default.md", "CULTURE.md"], "OpenRig's, then the rig's")
        #expect(byKind[.culture]?.files.map(\.delivery) == [.merged(into: "CLAUDE.md"), .merged(into: "CLAUDE.md")])
        #expect(byKind[.culture]?.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } == true)
        #expect(byKind[.pod]?.files.map(\.delivery) == [.merged(into: "CLAUDE.md")])
        #expect(byKind[.seat]?.files.map(\.path) == ["guidance/lead-first-move.md"])
        #expect(byKind[.notes]?.files.map(\.delivery) == [.sent])
        #expect(byKind[.openRig]?.files.first?.url.path.hasSuffix("daemon/assets/guidance/openrig-start.md") == true)
    }

    @Test func aCodexSeatMergesIntoAgentsMd() throws {
        let draft = try draft()
        let review = try #require(draft.seats.first { $0.member == "review" })
        let layers = draft.guidance(for: review, project: project, assets: nil)
        #expect(layers.map(\.kind) == [.project, .role, .culture, .pod, .notes], "no member files; no assets known")
        #expect(layers[0].files.isEmpty && layers[0].what.contains("No AGENTS.md"))
        #expect(layers[2].files.map(\.delivery) == [.merged(into: "AGENTS.md")])
    }

    @Test func autoDeliveryIsResolvedAsOpenRigDoes() {
        #expect(RigDraft.delivery("auto", path: "guidance/role.md", orientation: nil, into: "C") == .sent)
        #expect(RigDraft.delivery("auto", path: "x/notes.md", orientation: "role", into: "C") == .sent)
        #expect(RigDraft.delivery("auto", path: "skills/a/SKILL.md", orientation: nil, into: "C") == .skill)
        #expect(RigDraft.delivery("auto", path: "CULTURE.md", orientation: nil, into: "C") == .merged(into: "C"))
        #expect(RigDraft.delivery("auto", path: "boot.txt", orientation: nil, into: "C") == .sent)
        #expect(
            RigDraft.delivery("guidance_merge", path: "boot.txt", orientation: nil, into: "C") == .merged(into: "C"))
        #expect(
            RigDraft.assets(besideShippedSpec: "/x/cli/daemon/specs/rigs/a/rig.yaml")?.path == "/x/cli/daemon/assets")
        #expect(RigDraft.assets(besideShippedSpec: "/Users/me/.openrig/specs/rig.yaml") == nil)
    }

    @Test func skillChoicesComeFromTheRolesPoolsAndTheProject() throws {
        let draft = try draft()
        let build = try #require(draft.seats.first { $0.member == "build" })
        #expect(draft.roleSkills(build) == ["systematic-debugging", "development-team"])
        let choices = draft.skillChoices(for: build, project: project, catalog: root.appending(path: "no-catalog"))
        #expect(choices.map(\.id) == ["test-driven-development", "house-style"], "the role's own are left out")
        #expect(choices.map(\.source) == [.openRig, .project])
        #expect(choices.first?.summary == "Does process/test-driven-development")
    }

    @Test func notesAndAddedSkillsGoToThatSeatOnly() throws {
        var draft = try draft()
        let tdd = try #require(
            draft.skillChoices(for: draft.seats[0], project: nil, catalog: nil).first {
                $0.id == "test-driven-development"
            })
        draft.seats[0].notes = "  You own the API.  \n"
        draft.seats[0].addedSkills = [tdd]
        let spec = try #require(try Yams.compose(yaml: draft.yaml()))
        let members = try #require(spec["pods"]?[0]?["members"]?.sequence)
        let files = try #require(members[0]["startup"]?["files"]?.sequence)
        #expect(
            files.map { $0["path"]?.string } == [
                "guidance/lead-first-move.md", "seat-notes/dev.build.md",
                "seat-skills/test-driven-development/SKILL.md",
            ])
        #expect(files.map { $0["delivery_hint"]?.string } == ["send_text", "send_text", "skill_install"])
        #expect(files[1]["required"]?.bool == true)
        #expect(members[1]["startup"] == nil, "the other seat is unchanged")
        #expect(try draft.yaml().contains("required: true"))

        #expect(
            draft.seatFiles == [
                "seat-notes/dev.build.md": .text("You own the API.\n"),
                "seat-skills/test-driven-development": .folder(tdd.folder),
            ])
        let out = root(appending: "out")
        try FileManager.default.createDirectory(
            at: out.appending(path: "seat-skills/stale"), withIntermediateDirectories: true)
        try draft.writeSeatFiles(into: out)
        #expect(
            try String(contentsOf: out.appending(path: "seat-notes/dev.build.md"), encoding: .utf8)
                == "You own the API.\n")
        let copied = out.appending(path: "seat-skills/test-driven-development")
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "references/a.md").path))
        #expect(
            !FileManager.default.fileExists(atPath: out.appending(path: "seat-skills/stale").path), "a removed one goes"
        )
    }

    @Test func blankNotesAddNothing() throws {
        var draft = try draft()
        draft.seats[1].notes = " \n "
        #expect(draft.seatFiles.isEmpty)
        let spec = try #require(try Yams.compose(yaml: draft.yaml()))
        #expect(spec["pods"]?[0]?["members"]?[1]?["startup"] == nil)
    }

    private func root(appending path: String) -> URL { root.appending(path: path) }
}

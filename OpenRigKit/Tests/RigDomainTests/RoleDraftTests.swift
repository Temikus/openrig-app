import Foundation
import Testing
import Yams

@testable import RigDomain

/// New role (rig builder, slice 4): reading the kernel lead's draft, checking it, and building the agent spec.
@Suite struct RoleDraftTests {
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "roledraft-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ path: String, _ text: String) throws {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static let agent = """
        name: migration-reviewer
        description: Checks every schema migration is reversible and safe on live data.
        defaults:
          runtime: codex
          model: gpt-5.5
          effort: high
        """
    static let guidance = "# Role: Migration reviewer\n\nReview each migration before it merges.\n"
    static let skills = """
        [{"id": "systematic-debugging", "why": "Finds the cause first"},
         {"id": "postgres-locks", "why": "Matches database"},
         {"id": "systematic-debugging", "why": "again"}]
        """

    /// A shared pool and a project skill, as `availableSkills` finds them.
    static func pool(_ folder: Folder) throws -> (shared: URL, project: URL, available: [SkillChoice]) {
        try folder.write(
            "shared/agent.yaml",
            "name: shared\nresources:\n  skills:\n    - id: systematic-debugging\n      path: skills/systematic-debugging\n"
        )
        try folder.write("shared/skills/systematic-debugging/SKILL.md", "---\ndescription: Debug it\n---\n")
        try folder.write("project/.claude/skills/migration-safety/SKILL.md", "---\ndescription: Ours\n---\n")
        let shared = folder.url.appending(path: "shared")
        let project = folder.url.appending(path: "project")
        return (shared, project, RoleDraft.availableSkills(shared: shared, project: project, catalog: nil))
    }

    @Test func aGoodDraftReadsBack() throws {
        let folder = Folder()
        try folder.write(RoleDraft.Files.agent, Self.agent)
        try folder.write(RoleDraft.Files.guidance, Self.guidance)
        try folder.write(RoleDraft.Files.skills, Self.skills)
        let draft = try RoleDraft.read(from: folder.url)
        #expect(draft.name == "migration-reviewer")
        #expect(draft.summary == "Checks every schema migration is reversible and safe on live data.")
        #expect(draft.guidance == Self.guidance)
        #expect(draft.runtime == "codex")
        #expect(draft.model == "gpt-5.5")
        #expect(draft.effort == "high")
        #expect(draft.skills.map(\.id) == ["systematic-debugging", "postgres-locks"], "a repeat is dropped")
        #expect(draft.problems(roles: ["qa"], taken: []).isEmpty)
    }

    @Test func aMissingOrMalformedFileIsAFailure() throws {
        let folder = Folder()
        try folder.write(RoleDraft.Files.agent, Self.agent)
        try folder.write(RoleDraft.Files.guidance, Self.guidance)
        #expect(throws: RoleDraft.Failure.missing(RoleDraft.Files.skills)) { try RoleDraft.read(from: folder.url) }
        try folder.write(RoleDraft.Files.skills, "{\"id\": 1}")
        #expect(throws: RoleDraft.Failure.self) { try RoleDraft.read(from: folder.url) }
        try folder.write(RoleDraft.Files.skills, "[]")
        try folder.write(RoleDraft.Files.agent, "just a line")
        #expect(throws: RoleDraft.Failure.self) { try RoleDraft.read(from: folder.url) }
    }

    @Test func anUnknownRuntimeFallsBackAndEmptyValuesAreLeftOut() throws {
        let folder = Folder()
        try folder.write(RoleDraft.Files.agent, "name: x\ndescription: y\ndefaults:\n  runtime: stub\n  model: \" \"\n")
        try folder.write(RoleDraft.Files.guidance, "g")
        try folder.write(RoleDraft.Files.skills, "[]")
        let draft = try RoleDraft.read(from: folder.url)
        #expect(draft.runtime == "claude-code", "a role defaults to an agent runtime, not the test stub")
        #expect(draft.model == nil)
    }

    @Test func unknownSkillsAreFlaggedAndNeverWritten() throws {
        let folder = Folder()
        let pool = try Self.pool(folder)
        var draft = RoleDraft(
            name: "migration-reviewer", summary: "s", guidance: "g",
            skills: [
                .init(id: "systematic-debugging", why: ""), .init(id: "postgres-locks", why: ""),
                .init(id: "migration-safety", why: ""),
            ])
        #expect(draft.unknownSkills(available: pool.available) == ["postgres-locks"])
        let files = draft.files(shared: pool.shared, available: pool.available)
        guard case .text(let yaml)? = files[RoleDraft.Files.agent] else { Issue.record("no agent.yaml"); return }
        let spec = try #require(try Yams.compose(yaml: yaml))
        let uses = spec["profiles"]?["default"]?["uses"]
        #expect(uses?["skills"]?.sequence?.compactMap(\.string) == ["systematic-debugging", "migration-safety"])
        // A project skill travels with the role: copied into it and declared as its own resource.
        #expect(
            files["skills/migration-safety"] == .folder(pool.project.appending(path: ".claude/skills/migration-safety"))
        )
        #expect(files["skills/systematic-debugging"] == nil, "the shared pool's comes through the import")
        #expect(spec["resources"]?["skills"]?.sequence?.first?["path"]?.string == "skills/migration-safety")
        // Unticked: left out.
        draft.skills[2].on = false
        let unticked = draft.files(shared: pool.shared, available: pool.available)
        #expect(unticked["skills/migration-safety"] == nil)
    }

    @Test func theSpecHasTheBuiltInRolesShape() throws {
        let folder = Folder()
        let pool = try Self.pool(folder)
        let draft = RoleDraft(
            name: "migration-reviewer", summary: "Checks migrations.", guidance: "# Role", runtime: "codex",
            model: "gpt-5.5", effort: "high")
        guard case .text(let yaml)? = draft.files(shared: pool.shared, available: [])[RoleDraft.Files.agent]
        else { Issue.record("no agent.yaml"); return }
        let spec = try #require(try Yams.compose(yaml: yaml))
        #expect(spec["name"]?.string == "migration-reviewer")
        #expect(spec["version"]?.string == "1.0")
        #expect(spec["description"]?.string == "Checks migrations.")
        #expect(spec["defaults"]?["runtime"]?.string == "codex")
        #expect(spec["defaults"]?["model"]?.string == "gpt-5.5")
        #expect(spec["imports"]?.sequence?.first?["ref"]?.string == "path:" + pool.shared.path(percentEncoded: false))
        #expect(spec["profiles"]?["default"]?["uses"]?["plugins"]?.sequence?.first?.string == "shared:openrig-core")
        let startup = try #require(spec["startup"]?["files"]?.sequence?.first)
        #expect(startup["path"]?.string == RoleDraft.Files.guidance)
        #expect(startup["orientation"]?.string == "role")
        // What it writes reads back as the same draft, so Draft Again and a saved role agree.
        try draft.write(into: folder.url.appending(path: "out"), shared: pool.shared, available: [])
        try folder.write("out/" + RoleDraft.Files.skills, "[]")
        let back = try RoleDraft.read(from: folder.url.appending(path: "out"))
        #expect(back.name == draft.name && back.summary == draft.summary && back.model == draft.model)
        #expect(back.guidance == "# Role\n")
    }

    @Test func badNamesAndClashesAreRefused() {
        #expect(RoleDraft.nameProblem("", roles: [], taken: []) == "Name the role.")
        #expect(RoleDraft.nameProblem("Migration Reviewer", roles: [], taken: []) != nil)
        #expect(RoleDraft.nameProblem("migration_reviewer", roles: [], taken: []) != nil)
        #expect(
            RoleDraft.nameProblem("qa", roles: ["qa"], taken: [])
                == "A role named qa already exists. Pick another name.")
        #expect(RoleDraft.nameProblem("payments", roles: [], taken: ["payments"])?.contains("folder") == true)
        #expect(RoleDraft.nameProblem("migration-reviewer", roles: ["qa"], taken: ["payments"]) == nil)
        let draft = RoleDraft(name: "qa", summary: " ", guidance: "")
        #expect(
            draft.problems(roles: ["qa"], taken: []) == [
                "A role named qa already exists. Pick another name.", "Add a summary.", "Add the guidance.",
            ])
    }

    @Test func theAskNamesTheFilesAndTheRealSkills() throws {
        let folder = Folder()
        let pool = try Self.pool(folder)
        let ask = RoleDraft.ask(
            line: "Reviews database migrations", project: "/code/app", folder: "/tmp/x", skills: pool.available)
        for needle in [
            "Reviews database migrations", "/code/app", "/tmp/x", "agent.yaml", "guidance/role.md", "skills.json",
            "READY", "- systematic-debugging (OpenRig): Debug it", "- migration-safety (Project): Ours",
        ] {
            #expect(ask.contains(needle), "\(needle)")
        }
    }
}

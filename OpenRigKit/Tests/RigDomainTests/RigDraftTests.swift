import Foundation
import Testing
import Yams

@testable import RigDomain

@Suite struct RigDraftTests {
    /// Shaped like the shipped templates: relative agent refs, a startup file, pod and rig edges.
    static let template = """
        version: "0.2"
        name: factory
        culture_file: CULTURE.md
        pods:
          - id: orch
            members:
              - id: lead
                agent_ref: "local:../../../agents/orchestration/orchestrator"
                runtime: codex
                profile: default
                cwd: "."
                startup:
                  files:
                    - path: guidance/lead-first-move.md
                      required: true
          - id: dev
            members:
              - id: build
                agent_ref: "local:../../../agents/development/implementer"
                runtime: claude-code
                model: opus
                effort: high
                profile: default
                cwd: "."
              - id: qa
                agent_ref: "local:../../../agents/development/qa"
                runtime: codex
                profile: default
            edges:
              - kind: delegates_to
                from: build
                to: qa
          - id: review
            members:
              - id: r1
                agent_ref: "local:../../../agents/review/independent-reviewer"
                runtime: claude-code
                profile: default
        edges:
          - kind: delegates_to
            from: orch.lead
            to: dev.build
          - kind: delegates_to
            from: orch.lead
            to: dev.qa
          - kind: can_observe
            from: review.r1
            to: dev.qa
        """
    static let folder = "/lib/specs/rigs/launch/factory"

    func draft() throws -> RigDraft { try RigDraft(template: Self.template, folder: Self.folder) }

    func parsed(_ draft: RigDraft) throws -> Node {
        try #require(try Yams.compose(yaml: try draft.yaml()))
    }

    func member(_ root: Node, _ pod: String, _ id: String) -> Node? {
        root["pods"]?.sequence?.first { $0["id"]?.string == pod }?["members"]?.sequence?.first {
            $0["id"]?.string == id
        }
    }

    @Test func readsEverySeatWithItsRuntimeModelAndEffort() throws {
        let seats = try draft().seats
        #expect(seats.map(\.id) == ["orch.lead", "dev.build", "dev.qa", "review.r1"])
        let build = try #require(seats.first { $0.id == "dev.build" })
        #expect(build.runtime == "claude-code")
        #expect(build.model == "opus")
        #expect(build.effort == "high")
        #expect(try draft().name == "factory")
    }

    @Test func theNameOverridesTheTemplates() throws {
        var draft = try draft()
        draft.name = "payments"
        #expect(try parsed(draft)["name"]?.string == "payments")
    }

    @Test func aRuntimeModelAndEffortChangeLandOnTheSeat() throws {
        var draft = try draft()
        draft.seats[0].runtime = "claude-code"
        draft.seats[0].model = "sonnet"
        draft.seats[0].effort = "medium"
        // Role default: the model and effort are left out.
        draft.seats[1].model = nil
        draft.seats[1].effort = nil
        let root = try parsed(draft)
        let lead = try #require(member(root, "orch", "lead"))
        #expect(lead["runtime"]?.string == "claude-code")
        #expect(lead["model"]?.string == "sonnet")
        #expect(lead["effort"]?.string == "medium")
        #expect(lead["startup"]?["files"]?.sequence?.first?["path"]?.string == "guidance/lead-first-move.md")
        let keys = lead.mapping.map { Array($0.keys.compactMap(\.string)) }
        #expect(keys == ["id", "agent_ref", "runtime", "model", "effort", "profile", "cwd", "startup"])
        let build = try #require(member(root, "dev", "build"))
        #expect(build["model"] == nil)
        #expect(build["effort"] == nil)
        #expect(root["culture_file"]?.string == "CULTURE.md")
    }

    @Test func removingASeatTakesItsEdgesWithIt() throws {
        var draft = try draft()
        draft.remove("dev.qa")
        let root = try parsed(draft)
        #expect(member(root, "dev", "qa") == nil)
        #expect(member(root, "dev", "build") != nil)
        let dev = root["pods"]?.sequence?.first { $0["id"]?.string == "dev" }
        #expect(dev?["edges"]?.sequence?.isEmpty == true)
        let edges = root["edges"]?.sequence?.map { "\($0["from"]?.string ?? "")>\($0["to"]?.string ?? "")" }
        #expect(edges == ["orch.lead>dev.build"])
    }

    @Test func removingAPodsLastSeatRemovesThePod() throws {
        var draft = try draft()
        draft.remove("review.r1")
        let root = try parsed(draft)
        #expect(root["pods"]?.sequence?.map { $0["id"]?.string } == ["orch", "dev"])
        #expect(root["edges"]?.sequence?.count == 2)
    }

    @Test func localRefsBecomeAbsolutePathRefs() throws {
        let root = try parsed(try draft())
        #expect(
            member(root, "dev", "build")?["agent_ref"]?.string == "path:/lib/specs/agents/development/implementer")
    }

    @Test func aTerminalSeatGetsTheTerminalTriple() throws {
        var draft = try draft()
        draft.seats[1].runtime = Runtime.terminal
        let build = try #require(member(try parsed(draft), "dev", "build"))
        #expect(build["agent_ref"]?.string == "builtin:terminal")
        #expect(build["runtime"]?.string == "terminal")
        #expect(build["profile"]?.string == "none")
        #expect(build["model"] == nil)
        #expect(build["effort"] == nil)
    }

    @Test func roleNameComesFromTheAgentSpec() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rigdraft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appending(path: "agents/qa")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try "name: qa-checker\nversion: \"1.0\"\n".write(
            to: agent.appending(path: "agent.yaml"), atomically: true, encoding: .utf8)
        let yaml = """
            name: t
            pods:
              - id: dev
                members:
                  - id: a
                    agent_ref: "local:agents/qa"
                    runtime: stub
                  - id: b
                    agent_ref: "local:agents/missing"
                    runtime: stub
            """
        let draft = try RigDraft(template: yaml, folder: root.path)
        #expect(draft.roleName(draft.seats[0]) == "qa-checker")
        #expect(draft.roleName(draft.seats[1]) == "missing")
    }
}

import Foundation
import Testing
import Yams

@testable import RigDomain

/// Blank rig and Add Seat (rig builder, slice 2).
@Suite struct AddSeatTests {
    /// Roles as folders, shaped like OpenRig's agent specs.
    static let roles = "/lib/specs/agents"
    static let orchestrator = roles + "/orchestration/orchestrator"
    static let implementer = roles + "/development/implementer"
    static let qa = roles + "/development/qa"

    /// Shaped like the shipped starter and research templates: same-pod and cross-pod edges.
    static func templates() throws -> [RigDraft] {
        let starter = """
            name: starter
            pods:
              - id: dev
                label: Project
                members:
                  - id: build
                    agent_ref: "local:../../../agents/development/implementer"
                    runtime: claude-code
                  - id: review
                    agent_ref: "local:../../../agents/development/qa"
                    runtime: codex
                edges:
                  - kind: delegates_to
                    from: build
                    to: review
            edges: []
            """
        let factory = """
            name: factory
            pods:
              - id: orch
                label: Orchestration
                members:
                  - id: lead
                    agent_ref: "local:../../../agents/orchestration/orchestrator"
                    runtime: claude-code
              - id: dev
                label: Development
                members:
                  - id: build
                    agent_ref: "local:../../../agents/development/implementer"
                    runtime: claude-code
                  - id: qa
                    agent_ref: "local:../../../agents/development/qa"
                    runtime: codex
            edges:
              - kind: delegates_to
                from: orch.lead
                to: dev.build
              - kind: delegates_to
                from: orch.lead
                to: dev.qa
            """
        return [
            try RigDraft(template: starter, folder: "/lib/specs/rigs/launch/starter"),
            try RigDraft(template: factory, folder: "/lib/specs/rigs/launch/factory"),
        ]
    }

    func parsed(_ draft: RigDraft) throws -> Node { try #require(try Yams.compose(yaml: try draft.yaml())) }

    func pod(_ root: Node, _ id: String) -> Node? { root["pods"]?.sequence?.first { $0["id"]?.string == id } }

    func role(_ folder: String, _ name: String) -> Role { Role(name: name, summary: "", folder: folder) }

    @Test func aBlankRigHasNoSeats() throws {
        var draft = RigDraft.blank()
        draft.name = "payments"
        #expect(draft.seats.isEmpty)
        #expect(draft.templateEdges.isEmpty)
        let root = try parsed(draft)
        #expect(root["name"]?.string == "payments")
        #expect(root["pods"]?.sequence?.isEmpty == true)
    }

    @Test func seatsAddedToABlankRigMakeAValidShape() throws {
        let rules = EdgeRules(learningFrom: try Self.templates())
        var draft = RigDraft.blank()
        draft.name = "payments"
        draft.cwd = "/code/payments"
        for (folder, name) in [(Self.orchestrator, "orchestrator"), (Self.implementer, "implementer")] {
            let (member, podID) = rules.suggestion(for: role(folder, name), taken: draft.takenMembers)
            let seat = RigDraft.Seat.added(pod: podID, member: member, role: folder, runtime: "claude-code")
            draft.add(seat, edges: rules.edges(for: seat, in: draft))
        }
        #expect(draft.seats.map(\.id) == ["orch.lead", "dev.build"])
        let root = try parsed(draft)
        let orch = try #require(pod(root, "orch"))
        #expect(orch["label"]?.string == "Orch", "OpenRig requires a pod label")
        let lead = try #require(orch["members"]?.sequence?.first)
        #expect(lead["agent_ref"]?.string == "path:" + Self.orchestrator)
        #expect(lead["profile"]?.string == "default")
        #expect(lead["runtime"]?.string == "claude-code")
        #expect(lead["cwd"]?.string == "/code/payments")
        // Across pods, so at rig level by logical id, as the factory template writes it.
        let edges = try #require(root["edges"]?.sequence)
        #expect(
            edges.map { [$0["kind"]?.string, $0["from"]?.string, $0["to"]?.string] } == [
                ["delegates_to", "orch.lead", "dev.build"]
            ])
    }

    @Test func aSeatAddedToATemplatePodJoinsItWithThePodsEdges() throws {
        let templates = try Self.templates()
        let rules = EdgeRules(learningFrom: templates)
        var draft = templates[0]
        let (member, podID) = rules.suggestion(for: role(Self.implementer, "implementer"), taken: draft.takenMembers)
        #expect((member, podID) == ("build2", "dev"), "build is taken")
        let seat = RigDraft.Seat.added(pod: podID, member: member, role: Self.implementer, runtime: "stub")
        draft.add(seat, edges: rules.edges(for: seat, in: draft))
        let dev = try #require(pod(try parsed(draft), "dev"))
        #expect(dev["members"]?.sequence?.map { $0["id"]?.string } == ["build", "review", "build2"])
        // Implementer → QA, in the pod by member id.
        #expect(
            dev["edges"]?.sequence?.map { [$0["from"]?.string, $0["to"]?.string] } == [
                ["build", "review"], ["build2", "review"],
            ])
    }

    @Test func aSeatInANewPodGetsItsEdgesAtRigLevel() throws {
        let templates = try Self.templates()
        let rules = EdgeRules(learningFrom: templates)
        var draft = templates[0]
        let seat = RigDraft.Seat.added(pod: "orch", member: "lead", role: Self.orchestrator, runtime: "stub")
        let edges = rules.edges(for: seat, in: draft)
        #expect(
            edges == [
                RigDraft.Edge(kind: "delegates_to", from: "orch.lead", to: "dev.build"),
                RigDraft.Edge(kind: "delegates_to", from: "orch.lead", to: "dev.review"),
            ], "the lead delegates to every implementer and QA seat")
        draft.add(seat, edges: edges)
        let root = try parsed(draft)
        #expect(root["pods"]?.sequence?.map { $0["id"]?.string } == ["dev", "orch"])
        #expect(root["edges"]?.sequence?.count == 2)
    }

    @Test func removingAnAddedSeatTakesItsEdges() throws {
        let templates = try Self.templates()
        let rules = EdgeRules(learningFrom: templates)
        var draft = templates[0]
        let seat = RigDraft.Seat.added(pod: "orch", member: "lead", role: Self.orchestrator, runtime: "stub")
        draft.add(seat, edges: rules.edges(for: seat, in: draft))
        draft.remove("orch.lead")
        #expect(draft.addedEdges.isEmpty)
        let root = try parsed(draft)
        #expect(root["pods"]?.sequence?.map { $0["id"]?.string } == ["dev"])
        #expect(root["edges"]?.sequence?.isEmpty == true)
    }

    @Test func seatNamesAreUniqueInTheRig() {
        #expect(SeatName.unique("build", taken: []) == "build")
        #expect(SeatName.unique("build", taken: ["build"]) == "build2")
        #expect(SeatName.unique("build", taken: ["build", "build2"]) == "build3")
        #expect(SeatName.unique("r1", taken: ["r1"]) == "r2")
        #expect(SeatName.from("Independent reviewer") == "independent-reviewer")
        #expect(SeatName.problem("build", taken: ["build"]) == "This rig already has a seat named build.")
        #expect(SeatName.problem("Build 2", taken: []) != nil)
        #expect(SeatName.problem("", taken: []) == "Name the seat.")
        #expect(SeatName.problem("build-2", taken: ["build"]) == nil)
        #expect(SeatName.podProblem("") == "Name the pod.")
        #expect(SeatName.podProblem("New Pod") != nil)
        #expect(SeatName.podProblem("review") == nil)
    }

    @Test func aRemovedTemplateSeatsNameStaysTaken() throws {
        var draft = try Self.templates()[0]
        draft.remove("dev.build")
        #expect(draft.takenMembers.contains("build"), "the template's text still has it")
    }

    @Test func aRoleWithoutUsualNamesIsNamedFromItself() {
        let rules = EdgeRules(learningFrom: [])
        let pick = rules.suggestion(for: role("/x/designer", "Product designer"), taken: [])
        #expect(pick.member == "product-designer")
        #expect(pick.pod == "dev")
    }

    @Test func rolesNeedADefaultProfile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "roles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func spec(_ name: String, _ yaml: String) throws -> URL {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "agent.yaml")
            try yaml.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        let qa = try spec("qa", "name: qa\ndescription: QA agent\nprofiles:\n  default:\n    uses: {}\n")
        let shared = try spec("shared", "name: shared\nprofiles: {}\n")
        #expect(Role.load(agentSpec: qa)?.name == "qa")
        // A role read from its file matches the same role named by a template's ref (the probe of slice 2 found the
        // trailing "/" kept them apart, so every suggestion fell back).
        let folder = try #require(Role.load(agentSpec: qa)?.folder)
        #expect(!folder.hasSuffix("/"))
        let draft = try RigDraft(
            template: "name: t\npods:\n  - id: dev\n    members:\n      - id: check\n        agent_ref: \"local:qa\"\n",
            folder: root.path)
        #expect(draft.roleFolder(draft.seats[0]) == folder)
        // Reached through a symlink, as an nvm or Homebrew path can be, it is still the same role (review of cf2eff9).
        let link = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let viaLink = try RigDraft(template: draft.template, folder: link.path)
        #expect(viaLink.roleFolder(viaLink.seats[0]) == folder)
        #expect(Role.load(agentSpec: qa)?.summary == "QA agent")
        #expect(Role.load(agentSpec: qa, summary: "From the library")?.summary == "From the library")
        #expect(Role.load(agentSpec: shared) == nil, "resources only, not a role")
    }
}

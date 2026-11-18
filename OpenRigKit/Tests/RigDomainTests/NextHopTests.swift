import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

@Suite struct NextHopTests {
    typealias Step = WorkflowSpec.Step

    func instance(_ steps: [Step], roles: [String: [String]], at step: String, status: String = "active")
        -> WorkflowInstance
    {
        WorkflowInstance(
            id: "wf", status: status, frontier: [.init(qitemID: "q1", stepID: step)],
            spec: WorkflowSpec(steps: steps, roles: roles))
    }

    let roles = ["planner": ["plan@r"], "builder": ["build@r"], "reviewer": ["review@r"]]
    let linear = [
        Step(id: "plan", role: "planner"), Step(id: "build", role: "builder"), Step(id: "review", role: "reviewer"),
    ]

    @Test func declarationOrderByDefault() {
        let hop = nextHop(for: "q1", in: [instance(linear, roles: roles, at: "plan")])
        #expect(hop == NextHop(qitemID: "q1", stepID: "plan", nextStepID: "build", owner: "build@r"))
        #expect(nextHop(for: "q1", in: [instance(linear, roles: roles, at: "review")]) == nil, "last step")
    }

    @Test func suggestedRolesJumpAhead() {
        var steps = linear
        steps[0].suggestedRoles = ["reviewer"]
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")])?.nextStepID == "review")
        // A suggested role with no step falls through to declaration order.
        steps[0].suggestedRoles = ["nobody"]
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")])?.nextStepID == "build")
    }

    @Test func modesStopTheGuess() {
        var steps = linear
        steps[0].nextMode = "forbid"
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")]) == nil)
        steps[0].nextMode = "require"
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")]) == nil, "owner chooses at close")
        steps[0].suggestedRoles = ["reviewer"]
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")])?.nextStepID == "review")
    }

    @Test func noOwnerWithoutPreferredTargets() {
        // The daemon resolves such a role live on the bound rig; the app can't say which seat.
        let hop = nextHop(for: "q1", in: [instance(linear, roles: ["planner": ["plan@r"]], at: "plan")])
        #expect(hop == nil)
    }

    @Test func harnessPinPicksAMatchingSeat() {
        var steps = linear
        steps[1].harness = "codex"
        let roles = ["builder": ["claude-builder@r", "codex-builder@r"]]
        let runtime = ["claude-builder@r": "claude-code", "codex-builder@r": "codex"]
        let hop = nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")], runtimeOf: { runtime[$0] })
        #expect(hop?.owner == "codex-builder@r")
        #expect(nextHop(for: "q1", in: [instance(steps, roles: roles, at: "plan")]) == nil, "runtime unknown")
    }

    @Test func onlyOpenPacketsOfLiveInstances() {
        #expect(nextHop(for: "other", in: [instance(linear, roles: roles, at: "plan")]) == nil)
        #expect(nextHop(for: "q1", in: [instance(linear, roles: roles, at: "plan", status: "completed")]) == nil)
    }

    /// Recorded from a two-step workflow started on a test rig; both steps target the same seat.
    @Test func recordedInstance() throws {
        let instances: [WorkflowInstance] = try RigFixtures.decode("workflow-list")
        let wf = try #require(instances.first)
        #expect(wf.status == "active")
        #expect(wf.spec.steps.map(\.id) == ["draft", "check"])
        let packet = try #require(wf.frontier.first)
        #expect(packet.stepID == "draft")
        let hop = nextHop(for: packet.qitemID, in: instances)
        #expect(hop?.nextStepID == "check")
        #expect(hop?.owner == "main-lead@openrig-apptest")
    }
}

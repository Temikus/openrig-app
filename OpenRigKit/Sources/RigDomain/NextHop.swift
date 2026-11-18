import RigModel

/// Where a workflow packet goes when its owner closes it normally.
public struct NextHop: Equatable, Sendable {
    public var qitemID: String
    public var stepID: String
    public var nextStepID: String
    /// The session that will own the next packet.
    public var owner: String

    public init(qitemID: String, stepID: String, nextStepID: String, owner: String) {
        self.qitemID = qitemID
        self.stepID = stepID
        self.nextStepID = nextStepID
        self.owner = owner
    }
}

/// The daemon's own rule (`resolveNextStep` and `resolveDefaultOwner` in rig 0.7.11's workflow projector),
/// for a normal close: no branch exit is known before the owner closes. Nil when the next step or its
/// owner is decided later: `require` or `forbid` mode, a role with no preferred seats, or an unknown runtime.
public func nextHop(
    for qitemID: String, in instances: [WorkflowInstance], runtimeOf: (String) -> String? = { _ in nil }
) -> NextHop? {
    for instance in instances where instance.status == "active" {
        guard let packet = instance.frontier.first(where: { $0.qitemID == qitemID }) else { continue }
        let spec = instance.spec
        guard let index = spec.steps.firstIndex(where: { $0.id == packet.stepID }),
            let next = nextStep(after: spec.steps[index], at: index, in: spec),
            let owner = owner(of: next, in: spec, runtimeOf: runtimeOf)
        else { return nil }
        return NextHop(qitemID: qitemID, stepID: packet.stepID, nextStepID: next.id, owner: owner)
    }
    return nil
}

private func nextStep(after step: WorkflowSpec.Step, at index: Int, in spec: WorkflowSpec) -> WorkflowSpec.Step? {
    if step.nextMode == "forbid" { return nil }
    for role in step.suggestedRoles {
        if let target = spec.steps.first(where: { $0.role == role }) { return target }
    }
    if step.nextMode == "require" { return nil }
    return spec.steps.indices.contains(index + 1) ? spec.steps[index + 1] : nil
}

private func owner(of step: WorkflowSpec.Step, in spec: WorkflowSpec, runtimeOf: (String) -> String?) -> String? {
    let targets = spec.roles[step.role] ?? []
    guard let harness = step.harness else { return targets.first }
    return targets.first { runtimeOf($0) == harness }
}

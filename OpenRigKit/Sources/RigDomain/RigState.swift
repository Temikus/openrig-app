import RigModel

/// A rig's state as its sidebar row shows it: a dot and one line under the name.
public struct RigLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case running
        /// Something is down that nobody stopped on purpose: look at this.
        case attention
        case stopped
    }

    public var tone: Tone
    public var text: String
}

public func rigLine(_ rig: RigSummary) -> RigLine {
    let seats = "\(rig.nodeCount) \(rig.nodeCount == 1 ? "seat" : "seats")"
    let partial = "\(rig.runningCount) of \(seats)"
    switch rig.lifecycle {
    case .running:
        // Seats stopped on purpose don't make a rig degraded, so the count can still be partial.
        let count = rig.runningCount < rig.nodeCount ? partial : seats
        return RigLine(
            tone: .running, text: [rig.uptime.map { "up \($0)" }, count].compactMap(\.self).joined(separator: " · "))
    case .degraded:
        return RigLine(tone: .attention, text: "degraded · \(partial)")
    case .attentionRequired:
        return RigLine(tone: .attention, text: "needs attention · \(partial)")
    case .recoverable:
        return RigLine(tone: .attention, text: "stopped unexpectedly · \(seats)")
    case .stopped:
        return RigLine(
            tone: .stopped,
            text: ["stopped", rig.latestSnapshot.map { "snapshot \($0)" }].compactMap(\.self).joined(separator: " · "))
    default:
        let tone: RigLine.Tone = rig.runningCount == 0 ? .stopped : .running
        return RigLine(tone: tone, text: "\(rig.runningCount)/\(rig.nodeCount) running")
    }
}

/// Whether Start applies: no seat of the rig is running.
public func isStopped(_ rig: RigSummary) -> Bool {
    rig.status == .stopped || (rig.runningCount == 0 && rig.nodeCount > 0)
}

/// Seats up out of all seats, for "Starting · 3 of 7 up".
public struct StartProgress: Equatable, Sendable {
    public var up: Int
    public var total: Int
}

public func startProgress(_ graph: RigGraph) -> StartProgress {
    StartProgress(up: graph.seats.filter { presence($0) == .live }.count, total: graph.seats.count)
}

/// What a stop would interrupt: seats mid-turn, and how many others are up and idle.
public struct StopRisk: Equatable, Sendable {
    public var working: [Seat]
    public var idle: Int

    public init(working: [Seat], idle: Int) {
        self.working = working
        self.idle = idle
    }
    /// Seats a stop would end.
    public var live: Int { working.count + idle }
}

public func stopRisk(_ graph: RigGraph) -> StopRisk {
    let live = graph.seats.filter { presence($0) == .live || presence($0) == .starting }
    let working = live.filter { $0.activity?.state == .running }
    return StopRisk(working: working, idle: live.count - working.count)
}

import Foundation
import RigModel

/// One permission prompt as the user saw it. Answering binds to this instance: if the seat's prompt
/// has changed by the time the button is pressed, the answer is withheld (PLAN.md, permission control).
public struct PromptInstance: Equatable, Sendable, Identifiable {
    public var seatID: Seat.ID
    public var session: String
    public var command: String
    public var observedAt: Date?

    public var id: String { "prompt:\(seatID)" }

    public init?(seat: Seat, stop: PermissionStop) {
        guard stop.state == .requestObserved, let session = seat.sessionName, let command = stop.command else {
            return nil
        }
        self.seatID = seat.id
        self.session = session
        self.command = command
        self.observedAt = stop.observedAt
    }

    public enum Check: Equatable, Sendable {
        /// Still the prompt on screen: safe to answer.
        case same
        /// A different prompt is up (other command, or the same command asked again).
        case changed
        /// Nothing is waiting any more.
        case gone
    }

    public func check(against current: PermissionStop) -> Check {
        guard current.state == .requestObserved, let command = current.command else { return .gone }
        return command == self.command && current.observedAt == observedAt ? .same : .changed
    }

    /// The daemon doesn't link a prompt to a qitem (PLAN.md gap 4). The seat's own active row is the best guess:
    /// its in-progress work first, else a row it holds.
    public func linkedQItem(in items: [QItem]) -> QItem? {
        let owned = items.filter { $0.destination == session && workStatus($0).isActive }
        return owned.first { workStatus($0) == .inProgress } ?? owned.first {
            if case .blocked = workStatus($0) { true } else { false }
        }
            ?? owned.first
    }
}

/// One row of the Needs-you strip and popover.
public enum NeedsYouEntry: Identifiable, Equatable, Sendable {
    case prompt(PromptInstance, linked: QItem?)
    case qitem(QItem)

    public var id: String {
        switch self {
        case .prompt(let p, _): p.id
        case .qitem(let q): "qitem:\(q.id)"
        }
    }
}

/// Live permission prompts first (they stall a turn), then held rows waiting on a person.
/// A held row already shown as a prompt's linked work isn't listed again.
public func needsYouEntries(prompts: [PromptInstance], items: [QItem]) -> [NeedsYouEntry] {
    let promptEntries = prompts.map { NeedsYouEntry.prompt($0, linked: $0.linkedQItem(in: items)) }
    let linked = Set(
        promptEntries.compactMap { entry -> String? in
            if case .prompt(_, let q) = entry { q?.id } else { nil }
        })
    return promptEntries + needsYou(items).filter { !linked.contains($0.id) }.map(NeedsYouEntry.qitem)
}

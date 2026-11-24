import Foundation
import RigModel

/// Rows a debug copy adds to its queue (OPENRIG_DEBUG_ROW), to show an ask nobody sent. Their source is often a real
/// seat, so no action on one may run: a Tell or a reply would type into that seat's terminal.
public struct MadeUpRows: Sendable {
    public let rows: [QItem]
    private let ids: Set<QItem.ID>

    /// One row or an array, as `rig queue show --json` prints them. Anything else reads as none.
    public init(json data: Data?) {
        let decoder = JSONDecoder()
        rows =
            data.flatMap { data in
                (try? decoder.decode([QItem].self, from: data))
                    ?? (try? decoder.decode(QItem.self, from: data)).map {
                        [$0]
                    }
            } ?? []
        ids = Set(rows.map(\.id))
    }

    /// The queue with the made-up rows it doesn't already hold, and the ids actually added: a real row with the same
    /// id wins.
    public func merge(into real: [QItem]) -> (rows: [QItem], added: Set<QItem.ID>) {
        let present = Set(real.map(\.id))
        let extra = rows.filter { !present.contains($0.id) }
        return (real + extra, Set(extra.map(\.id)))
    }

    public func contains(_ id: QItem.ID) -> Bool { ids.contains(id) }

    /// True when `action`, run under the control `key`, would touch a made-up row: the row is named in the key (the
    /// For You panel's "answer:<id>", its reply composer) or in the action itself.
    public func refuses(_ action: RigAction, key: String) -> Bool {
        if ids.contains(where: { key.contains($0) }) { return true }
        return action.rowID.map(ids.contains) ?? false
    }
}

extension RigAction {
    /// The queue row the action changes, if it names one.
    var rowID: String? {
        switch self {
        case .handoff(let id, _, _, _), .block(let id, _, _, _), .close(let id, _, _, _), .note(let id, _),
            .newDeadline(let id, _), .resolve(let id, _):
            id
        case .send, .create, .answerPrompt, .clearAttention, .startDaemon, .rigUp, .rigDown, .launchSeat,
            .freshSeat:
            nil
        }
    }
}

import Foundation
import RigModel

/// The fields of a daemon event that say which rig, seat or row it is about.
/// Queue and seat-activity events carry no `rigId`; they name sessions, a seat node or a row instead.
public struct EventPlace: Sendable, Equatable {
    public var type: String
    public var rigId: String?
    public var nodeId: String?
    public var seatNodeId: String?
    public var sessionName: String?
    public var sourceSession: String?
    public var destinationSession: String?
    public var fromSession: String?
    public var toSession: String?
    /// Who acted. The only session `queue.updated`, `queue.answer_recorded` and `mission_control.*` name.
    public var actorSession: String?
    public var qitemId: String?

    public init(
        type: String, rigId: String? = nil, nodeId: String? = nil, seatNodeId: String? = nil,
        sessionName: String? = nil, sourceSession: String? = nil, destinationSession: String? = nil,
        fromSession: String? = nil, toSession: String? = nil, actorSession: String? = nil, qitemId: String? = nil
    ) {
        self.type = type
        self.rigId = rigId
        self.nodeId = nodeId
        self.seatNodeId = seatNodeId
        self.sessionName = sessionName
        self.sourceSession = sourceSession
        self.destinationSession = destinationSession
        self.fromSession = fromSession
        self.toSession = toSession
        self.actorSession = actorSession
        self.qitemId = qitemId
    }

    /// Decodes the payload the stream sent. A payload that isn't a JSON object places nothing.
    public init(type: String, payload: Data) {
        // Each field is read on its own, so a retyped field becomes nil and the rest still place the event.
        let object = (try? JSONDecoder().decode([String: JSONValue].self, from: payload)) ?? [:]
        func field(_ key: String) -> String? {
            if case .string(let value) = object[key] { value } else { nil }
        }
        self.init(
            type: type, rigId: field("rigId"), nodeId: field("nodeId"), seatNodeId: field("seatNodeId"),
            sessionName: field("sessionName"), sourceSession: field("sourceSession"),
            destinationSession: field("destinationSession"), fromSession: field("fromSession"),
            toSession: field("toSession"), actorSession: field("actorSession"), qitemId: field("qitemId"))
    }

    /// Sessions that place the event. The actor counts only when no other session is named.
    var sessions: [String] {
        let named = [sessionName, sourceSession, destinationSession, fromSession, toSession].compactMap { $0 }
        return named.isEmpty ? [actorSession].compactMap { $0 } : named
    }

    /// Sessions the event delivers a row to.
    var destinations: [String] { [destinationSession, toSession].compactMap { $0 } }

    var family: Substring { type.split(separator: ".").first ?? "" }
}

/// What the app holds when an event arrives.
public struct EventContext {
    /// The selected rig. Nil when none is selected.
    public var rigID: String?
    public var rigName: String?
    /// Node ids of the selected rig's seats.
    public var seatIDs: Set<String>
    /// Whether the selected rig's store holds a row.
    public var holdsRow: (String) -> Bool
    /// The person's addresses.
    public var addresses: Set<String>
    /// Whether the rows for the person include a row.
    public var holdsRowForMe: (String) -> Bool

    public init(
        rigID: String?, rigName: String?, seatIDs: Set<String> = [],
        holdsRow: @escaping (String) -> Bool = { _ in false },
        addresses: Set<String>, holdsRowForMe: @escaping (String) -> Bool = { _ in false }
    ) {
        self.rigID = rigID
        self.rigName = rigName
        self.seatIDs = seatIDs
        self.holdsRow = holdsRow
        self.addresses = addresses
        self.holdsRowForMe = holdsRowForMe
    }
}

/// What an event asks the app to re-read.
public struct EventReach: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let refreshRig = EventReach(rawValue: 1 << 0)
    public static let pokeTerminals = EventReach(rawValue: 1 << 1)
    public static let refreshRowsForMe = EventReach(rawValue: 1 << 2)
    public static let refreshRigList = EventReach(rawValue: 1 << 3)
}

/// Decides what an event changes, so the app re-reads only that.
/// An event that names no rig, session, seat or row refreshes the selected rig: an unknown shape stays safe.
/// Known gap: `queue.updated` on a row the app doesn't hold, by an actor outside the rig, is skipped.
public func eventReach(_ event: EventPlace, in context: EventContext) -> EventReach {
    if event.family == "snapshot" || event.family == "watchdog" { return [] }
    var reach: EventReach = []
    if event.family == "rig" { reach.insert(.refreshRigList) }
    if event.family == "queue", isForMe(event, in: context) { reach.insert(.refreshRowsForMe) }
    if context.rigID != nil || context.rigName != nil, onSelectedRig(event, in: context) {
        reach.insert(.refreshRig)
        if event.type == "seat.activity_changed" { reach.insert(.pokeTerminals) }
    }
    return reach
}

private func onSelectedRig(_ event: EventPlace, in context: EventContext) -> Bool {
    if let rigId = event.rigId { return rigId == context.rigID }
    let seat = event.seatNodeId ?? event.nodeId
    let sessions = event.sessions
    guard !sessions.isEmpty || seat != nil || event.qitemId != nil else { return true }
    if let name = context.rigName, sessions.contains(where: { rigName(ofSession: $0) == name }) { return true }
    if let seat, context.seatIDs.contains(seat) { return true }
    if let id = event.qitemId, context.holdsRow(id) { return true }
    return false
}

private func isForMe(_ event: EventPlace, in context: EventContext) -> Bool {
    if event.destinations.contains(where: context.addresses.contains) { return true }
    if let id = event.qitemId, context.holdsRowForMe(id) { return true }
    return false
}

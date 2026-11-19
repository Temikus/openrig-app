import Foundation
import RigModel

/// What a banner is about; each kind has its own switch in Settings › Notifications.
public enum NoticeKind: String, CaseIterable, Sendable {
    case permission, ask, reply, seatDown, otherRig, daemonDown
}

/// Where clicking a banner takes the person.
public enum NoticeTarget: Equatable, Sendable {
    case seat(rig: String, session: String)
    case qitem(String)
    case rig(String)
    case app
}

/// One banner the app could post. `key` names the thing it's about, so a refresh never posts it twice.
public struct Notice: Equatable, Sendable {
    public var key: String
    public var kind: NoticeKind
    public var title: String
    public var body: String
    public var target: NoticeTarget
}

/// Remembers what is already waiting, so only new things become banners.
public struct NoticeTracker: Sendable {
    /// Nil until the first update: what waits at launch is shown in the app, not replayed as banners.
    private var seen: Set<String>?

    public init() {}

    /// The notices in `current` that weren't there last time and whose kind is enabled. Something that leaves and
    /// comes back posts again.
    public mutating func update(_ current: [Notice], enabled: Set<NoticeKind>) -> [Notice] {
        let keys = Set(current.map(\.key))
        defer { seen = keys }
        guard let seen else { return [] }
        return current.filter { !seen.contains($0.key) && enabled.contains($0.kind) }
    }
}

/// Banners for one rig's Needs-you list. Prompts name the command; the prompt's command and time are in its key, so
/// a new prompt on the same seat posts again.
public func notices(entries: [NeedsYouEntry], rig: String, me: String) -> [Notice] {
    entries.compactMap { entry in
        switch entry {
        case .prompt(let p, _):
            let when = p.observedAt.map { String($0.timeIntervalSince1970) } ?? ""
            return Notice(
                key: "prompt:\(p.seatID):\(p.command):\(when)", kind: .permission,
                title: "\(seatName(p.session)) needs permission", body: "Wants to run \"\(p.command)\" in \(rig).",
                target: .seat(rig: rig, session: p.session))
        case .seat(let seat, _):
            let session = seat.sessionName ?? seat.logicalId
            return Notice(
                key: "seat:\(seat.id)", kind: .seatDown, title: "\(seatName(session)) went down",
                body: "Open \(rig) to bring it back.", target: .seat(rig: rig, session: session))
        case .qitem(let item):
            return notice(for: item, me: me)
        }
    }
}

/// A row for the person: an ask, or a reply (an FYI).
public func notice(for item: QItem, me: String) -> Notice? {
    guard let kind = forYou(item, me: me) else { return nil }
    let from = seatName(item.source)
    return kind == .update
        ? Notice(
            key: "qitem:\(item.id)", kind: .reply, title: "\(from) replied", body: item.summary,
            target: .qitem(item.id))
        : Notice(
            key: "qitem:\(item.id)", kind: .ask, title: "\(from) asks you", body: item.summary,
            target: .qitem(item.id))
}

/// Other rigs, whose prompts the app doesn't read: the daemon's count of seats needing the person. The count is in the
/// key, so a rise posts and a steady count doesn't.
public func attentionNotices(_ counts: [String: Int]) -> [Notice] {
    counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { rig, count in
        Notice(
            key: "attention:\(rig):\(count)", kind: .otherRig,
            title: "\(rig): \(count) \(count == 1 ? "seat needs" : "seats need") you",
            body: "Open the rig to see what it's waiting on.", target: .rig(rig))
    }
}

/// The daemon has stopped answering, once it has been down for `grace`, so a restart doesn't ping. One per outage.
public func daemonDownNotice(since: Date?, now: Date, grace: TimeInterval = 30) -> Notice? {
    guard let since, now.timeIntervalSince(since) >= grace else { return nil }
    return Notice(
        key: "daemon-down:\(since.timeIntervalSince1970)", kind: .daemonDown,
        title: "The OpenRig daemon stopped answering",
        body: "No banners arrive until it's back. Open OpenRig to start it.", target: .app)
}

/// "orch-lead" from "orch-lead@denkeeper".
func seatName(_ session: String) -> String {
    session.split(separator: "@").first.map(String.init) ?? session
}

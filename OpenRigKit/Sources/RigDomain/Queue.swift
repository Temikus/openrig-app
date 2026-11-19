import Foundation
import RigModel

// MARK: - Status

public enum Blocker: Equatable, Sendable {
    /// Held until another qitem moves.
    case qitem(String)
    /// Waiting on something outside the rig: a person, a PR decision, CI. The human has to act.
    case outside(String)
}

/// A qitem's state with the daemon's two handoff encodings folded into one.
public enum WorkStatus: Equatable, Sendable {
    case pending, inProgress
    case blocked(on: Blocker)
    case closed(reason: String?)
    /// `state: "handed-off"`, or `state: "done"` with `closureReason: "handed_off_to"`.
    case handedOff(to: String?)
    case unknown(String)

    public var isActive: Bool {
        switch self {
        case .closed, .handedOff: false
        default: true
        }
    }

    public var needsYou: Bool {
        if case .blocked(on: .outside) = self { true } else { false }
    }
}

public func workStatus(_ item: QItem) -> WorkStatus {
    switch item.state {
    case .pending: return .pending
    case .inProgress: return .inProgress
    case .blocked:
        let ref = item.blockedOn ?? "unknown"
        return .blocked(on: ref.hasPrefix("qitem-") ? .qitem(ref) : .outside(ref))
    case .handedOff:
        return .handedOff(to: item.closureTarget ?? item.handedOffTo)
    case .done:
        if item.closureReason == "handed_off_to" { return .handedOff(to: item.closureTarget ?? item.handedOffTo) }
        return .closed(reason: item.closureReason)
    case .canceled:
        return .closed(reason: item.closureReason ?? "canceled")
    default:
        return .unknown(item.state.rawValue)
    }
}

public func isOverdue(_ item: QItem, now: Date) -> Bool {
    guard let closeBy = item.closeBy else { return false }
    return workStatus(item).isActive && closeBy < now
}

/// What an agent sent the person: something to decide, or an FYI.
public enum ForYou: Equatable, Sendable {
    case decision, update
}

/// A live row addressed to the person: `me`, or the unnamed person, whom agents also reply to.
public func forYou(_ item: QItem, me: String) -> ForYou? {
    guard item.destination == me || Human.isYou(item.destination) else { return nil }
    switch workStatus(item) {
    case .pending, .inProgress: return item.humanIntent == "update" && !item.asksHuman ? .update : .decision
    default: return nil
    }
}

/// Rows waiting on the person, oldest first: held rows, questions and decisions, then FYIs.
public func needsYou(_ items: [QItem], me: String = Human.session) -> [QItem] {
    let oldestFirst: (QItem, QItem) -> Bool = { ($0.updated ?? .distantPast) < ($1.updated ?? .distantPast) }
    let waiting = items.filter { item in
        let status = workStatus(item)
        return status.needsYou || (status.isActive && item.asksHuman) || forYou(item, me: me) == .decision
    }
    let updates = items.filter { forYou($0, me: me) == .update }
    return waiting.sorted(by: oldestFirst) + updates.sorted(by: oldestFirst)
}

/// The rig a seat's session belongs to: "orch-lead@denkeeper" → "denkeeper".
public func rigName(ofSession session: String) -> String? {
    guard let at = session.lastIndex(of: "@") else { return nil }
    let name = session[session.index(after: at)...]
    return name.isEmpty ? nil : String(name)
}

/// Rows addressed to the person by seats on rigs other than `rig`, in Needs-you order. A rig's queue only
/// lists its own seats' rows, so these would otherwise wait unseen until that rig is selected.
public func forYouElsewhere(_ items: [QItem], me: String, excluding rig: String?) -> [QItem] {
    needsYou(
        items.filter { item in
            guard forYou(item, me: me) != nil, let from = rigName(ofSession: item.source) else { return false }
            return from != rig
        }, me: me)
}

// MARK: - Chain of record

public struct Chain: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        case loaded(QItem)
        /// An ancestor known only by id, e.g. older than the list window.
        case missing(String)

        public var id: String {
            switch self {
            case .loaded(let item): item.id
            case .missing(let id): id
            }
        }
    }

    /// Oldest first.
    public var links: [Link]
    /// Index of the item the chain was built for.
    public var focusIndex: Int
    /// Successors not on the main line (the main line follows the earliest).
    public var branchCount: Int

    public var ids: [String] { links.map(\.id) }
}

/// Reconstructs handoff chains from queue rows.
/// Backwards it follows `handedOffFrom`, and fills ancestors outside the loaded rows from `chainOfRecord`.
/// Forwards it follows the rows that name each item as `handedOffFrom`.
public struct ChainIndex: Sendable {
    let byID: [String: QItem]
    let successors: [String: [QItem]]

    public init(_ items: [QItem]) {
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        successors = Dictionary(grouping: items.filter { $0.handedOffFrom != nil }, by: { $0.handedOffFrom! })
            .mapValues { $0.sorted { ($0.created ?? .distantPast, $0.id) < ($1.created ?? .distantPast, $1.id) } }
    }

    public func chain(for id: String) -> Chain {
        guard let focus = byID[id] else { return Chain(links: [.missing(id)], focusIndex: 0, branchCount: 0) }
        var visited: Set<String> = [id]

        var ancestors: [Chain.Link] = []
        var current = focus
        while let previous = current.handedOffFrom, !visited.contains(previous) {
            if let loaded = byID[previous] {
                ancestors.insert(.loaded(loaded), at: 0)
                visited.insert(previous)
                current = loaded
                continue
            }
            // Not loaded: the daemon's record on the oldest loaded row names the rest.
            var record = current.chainOfRecord ?? []
            if record.last != previous { record.append(previous) }
            let missing = record.filter { !visited.contains($0) }
            ancestors.insert(contentsOf: missing.map { .missing($0) }, at: 0)
            break
        }

        var descendants: [Chain.Link] = []
        var branches = 0
        current = focus
        while let next = successors[current.id]?.first(where: { !visited.contains($0.id) }) {
            branches += (successors[current.id]?.count ?? 1) - 1
            descendants.append(.loaded(next))
            visited.insert(next.id)
            current = next
        }

        return Chain(
            links: ancestors + [.loaded(focus)] + descendants, focusIndex: ancestors.count, branchCount: branches)
    }
}

// MARK: - Seat queue and selection

public struct SeatQueue: Equatable, Sendable {
    public var needsYou: [QItem]
    public var owned: [QItem]
    public var delegated: [QItem]
}

/// A seat's active work, as the inspector's Queue tab groups it. Newest first within each group.
public func seatQueue(for session: String, in items: [QItem]) -> SeatQueue {
    let active = items.filter { workStatus($0).isActive }
        .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    let mine = active.filter { $0.destination == session }
    return SeatQueue(
        needsYou: mine.filter { workStatus($0).needsYou || $0.asksHuman },
        owned: mine.filter { !workStatus($0).needsYou && !$0.asksHuman },
        delegated: active.filter { $0.source == session && $0.destination != session }
    )
}

/// The design's selection rule: clicking a seat keeps the selected qitem if it involves that seat;
/// otherwise it selects the seat's first Needs-you item, then Owned, then Delegated.
public func qitemSelection(afterSelecting session: String, current: QItem.ID?, in items: [QItem]) -> QItem.ID? {
    if let current, let item = items.first(where: { $0.id == current }),
        item.source == session || item.destination == session
    {
        return current
    }
    let queue = seatQueue(for: session, in: items)
    return (queue.needsYou.first ?? queue.owned.first ?? queue.delegated.first)?.id
}

// MARK: - Board

public struct BoardFilter: Equatable, Sendable {
    public enum Scope: String, CaseIterable, Sendable {
        case active = "Active"
        case today = "Today"
    }

    public var scope: Scope
    /// A session name; matches rows it sent or owns.
    public var seat: String?
    public var overdueOnly: Bool
    public var search: String

    public init(scope: Scope = .active, seat: String? = nil, overdueOnly: Bool = false, search: String = "") {
        self.scope = scope
        self.seat = seat
        self.overdueOnly = overdueOnly
        self.search = search
    }
}

public struct Board: Equatable, Sendable {
    public var pending: [QItem] = []
    public var inProgress: [QItem] = []
    public var blocked: [QItem] = []
    public var closed: [QItem] = []
    public var handedOff: [QItem] = []

    public var all: [QItem] { pending + inProgress + blocked + closed + handedOff }
}

public func board(_ items: [QItem], filter: BoardFilter, now: Date, calendar: Calendar = .current) -> Board {
    let query = filter.search.trimmingCharacters(in: .whitespaces).lowercased()
    var out = Board()
    let sorted = items.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    for item in sorted {
        let status = workStatus(item)
        if !status.isActive {
            guard filter.scope == .today, let updated = item.updated, calendar.isDate(updated, inSameDayAs: now)
            else { continue }
        }
        if let seat = filter.seat, item.source != seat, item.destination != seat { continue }
        if filter.overdueOnly && !isOverdue(item, now: now) { continue }
        if !query.isEmpty {
            let haystack = [item.summary, item.id, shortQItemID(item.id)].joined(separator: " ").lowercased()
            guard haystack.contains(query) else { continue }
        }
        switch status {
        case .pending: out.pending.append(item)
        case .inProgress, .unknown: out.inProgress.append(item)
        case .blocked: out.blocked.append(item)
        case .closed: out.closed.append(item)
        case .handedOff: out.handedOff.append(item)
        }
    }
    return out
}

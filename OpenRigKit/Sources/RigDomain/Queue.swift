import Foundation
import RigModel

// MARK: - Status

public enum Blocker: Equatable, Sendable {
    /// Held until another qitem moves.
    case qitem(String)
    /// Held on another agent's seat (`dev-qa@openrig-app`): agents settle it, not the person.
    case seat(String)
    /// Waiting on something outside the rig: a person, a PR decision, CI. The human has to act.
    case outside(String)

    /// The daemon's `blockedOn`: a qitem id, an agent's session, or anything else (a person's session,
    /// `external:…`). People and shared channels are `<id>@external`; the unnamed person is `human@host`.
    public init(ref: String) {
        if ref.hasPrefix("qitem-") {
            self = .qitem(ref)
        } else if ref.contains("@"), !ref.hasSuffix("@external"), !Human.isAddress(ref) {
            self = .seat(ref)
        } else {
            self = .outside(ref)
        }
    }
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
        return .blocked(on: Blocker(ref: item.blockedOn ?? "unknown"))
    case .handedOff:
        return .handedOff(to: item.closureTarget ?? item.handedOffTo)
    case .done:
        if item.closureReason == "handed_off_to" { return .handedOff(to: item.closureTarget ?? item.handedOffTo) }
        return .closed(reason: item.closureReason)
    case .canceled:
        return .closed(reason: item.closureReason ?? "canceled")
    case .denied:
        return .closed(reason: item.closureReason ?? "denied")
    case .failed:
        return .closed(reason: item.closureReason ?? "failed")
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
    case .pending, .inProgress:
        if isSweepFinding(item) { return .update }
        return item.humanIntent == "update" && !item.asksHuman ? .update : .decision
    default: return nil
    }
}

/// A notice the daemon's stuck sweep filed about another row. It carries no intent, but there is nothing to
/// approve: the person acts on the row it names, and the sweep closes the notice.
public func isSweepFinding(_ item: QItem) -> Bool { item.tags.contains("stuck-sweep-finding") }

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

/// How a finished row ended, as one plain word, instead of the daemon's closure reason (`no-follow-on`).
public enum Outcome: Equatable, Sendable {
    case approved, denied, answered, done, canceled, failed
    case replaced(by: String?)
    case escalated(to: String?)
    case handedOff(to: String?)

    public var label: String {
        switch self {
        case .approved: "Approved"
        case .denied: "Denied"
        case .answered: "Answered"
        case .done: "Done"
        case .canceled: "Canceled"
        case .failed: "Failed"
        case .replaced: "Replaced"
        case .escalated: "Escalated"
        case .handedOff: "Handed off"
        }
    }
}

/// nil while the row is open. An approval is a `no-follow-on` close whose resolution starts "Approved", as the app's
/// answer and the TUI's approve both write it; an answered ask carries its picks in `humanAnswers`.
public func outcome(_ item: QItem) -> Outcome? {
    switch workStatus(item) {
    case .handedOff(let to): return .handedOff(to: to)
    case .closed(let reason):
        // The state says it before any closure reason does.
        if item.state == .denied { return .denied }
        if item.state == .failed { return .failed }
        switch reason {
        case "denied": return .denied
        case "canceled": return .canceled
        case "superseded": return .replaced(by: item.closureTarget)
        case "escalation": return .escalated(to: item.closureTarget)
        default:
            let resolution = (item.resolution ?? "").lowercased()
            if resolution.hasPrefix("approved") { return .approved }
            if resolution.hasPrefix("denied") { return .denied }
            // An ask closed by the daemon's `answer`: the picks are on the row, the resolution is empty.
            if !item.humanAnswers.isEmpty { return .answered }
            return .done
        }
    default: return nil
    }
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

/// Every rig's asks of the person, for the Needs You window: decisions and rows held on the person or an outside
/// gate, oldest asked first, then FYIs. The same rows Needs you lists for one rig; each once.
public func humanQueue(_ items: [QItem], me: String) -> [QItem] {
    var seen = Set<QItem.ID>()
    let open = needsYou(items.filter { seen.insert($0.id).inserted }, me: me)
    let asked: (QItem) -> Date = { $0.created ?? $0.updated ?? .distantPast }
    let (fyis, asks) = (open.filter { forYou($0, me: me) == .update }, open.filter { forYou($0, me: me) != .update })
    return asks.sorted { asked($0) < asked($1) } + fyis.sorted { asked($0) < asked($1) }
}

/// The seat waiting on the person's answer: the sender of a row to the person, else the owner of a held row.
public func askedBy(_ item: QItem, me: String) -> String {
    forYou(item, me: me) != nil ? item.source : item.destination
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

public enum BoardDirection: Sendable { case up, down, left, right }

/// The card an arrow key moves to on the board, given each column's card ids top to bottom. Up and down stay in the
/// column; left and right skip empty columns and keep the row where they can. With nothing (or something no longer
/// shown) selected, the first card.
public func boardMove<ID: Equatable>(_ columns: [[ID]], from current: ID?, _ direction: BoardDirection) -> ID? {
    let first = columns.first { !$0.isEmpty }?.first
    guard let current, let col = columns.firstIndex(where: { $0.contains(current) }),
        let row = columns[col].firstIndex(of: current)
    else { return first }
    switch direction {
    case .up: return columns[col][max(row - 1, 0)]
    case .down: return columns[col][min(row + 1, columns[col].count - 1)]
    case .left, .right:
        let step = direction == .left ? -1 : 1
        var next = col + step
        while columns.indices.contains(next), columns[next].isEmpty { next += step }
        guard columns.indices.contains(next) else { return current }
        return columns[next][min(row, columns[next].count - 1)]
    }
}

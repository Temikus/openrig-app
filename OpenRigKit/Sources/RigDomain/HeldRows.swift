import Foundation
import RigModel

/// A rig's rows, from three reads merged by id: its open rows, its rows closed since a time (today),
/// and single rows read by id (a selected closed row, the ancestors in its chain).
public struct HeldRows: Sendable, Equatable {
    public private(set) var open: [String: QItem] = [:]
    public private(set) var closed: [String: QItem] = [:]
    public private(set) var byID: [String: QItem] = [:]
    /// The start of the closed rows' window. Nil when closed rows are not held.
    public private(set) var closedSince: Date?

    /// The states the open read asks for (`DaemonHTTP.openStates`). Every other state is closed.
    public static let openStates: Set<QItemState> = [.pending, .inProgress, .blocked]

    public init() {}

    /// Replaces the open rows with a fresh read. A row kept by id goes when the read serves it, or when the
    /// kept copy is open and the read leaves it out: it closed or moved, and only a new read by id is current.
    public mutating func replaceOpen(_ rows: [QItem]) {
        open = Self.index(rows)
        byID = byID.filter { id, row in open[id] == nil && !Self.openStates.contains(row.state) }
    }

    /// Replaces the closed rows with a read of rows closed at or after `since`.
    public mutating func replaceClosed(_ rows: [QItem], since: Date) {
        closed = Self.index(Self.closed(rows, since: since))
        closedSince = since
    }

    /// Adds rows from a top-up read, replacing older copies.
    public mutating func topUpClosed(_ rows: [QItem]) {
        guard let closedSince else { return }
        for row in Self.closed(rows, since: closedSince) { closed[row.id] = row }
    }

    /// An older daemon may ignore the read's `state` or `updatedSince` filter, so both are checked here too.
    private static func closed(_ rows: [QItem], since: Date) -> [QItem] {
        rows.filter { !openStates.contains($0.state) && ($0.updated.map { $0 >= since } ?? false) }
    }

    /// Stops holding closed rows, e.g. when no view shows them.
    public mutating func dropClosed() {
        closed = [:]
        closedSince = nil
    }

    /// Keeps a row read by id. A closed row stays until the store is reset; an open one, until `replaceOpen`.
    public mutating func keep(_ row: QItem) {
        byID[row.id] = row
    }

    /// Whether a selected row must be read by id: no read serves it, and no closed copy is kept. A closed row
    /// doesn't change, so its kept copy is read once.
    public func needsRead(_ id: String) -> Bool {
        guard open[id] == nil, closed[id] == nil else { return false }
        guard let kept = byID[id] else { return true }
        return Self.openStates.contains(kept.state)
    }

    /// The closed rows' window began before `startOfToday`: it is yesterday's, and the rows need reading again.
    public func closedWindowIsStale(startOfToday: Date) -> Bool {
        closedSince.map { $0 < startOfToday } ?? false
    }

    /// The time to ask for closed rows updated since. Nil when closed rows are not held.
    /// It repeats the newest row's time, so a row updated in the same instant is not missed.
    public var topUpSince: Date? {
        guard let closedSince else { return nil }
        return closed.values.compactMap(\.updated).reduce(closedSince, max)
    }

    public func row(_ id: String) -> QItem? {
        [closed[id], byID[id], open[id]].compactMap { $0 }.reduce(nil, Self.newer)
    }

    public func holds(_ id: String) -> Bool {
        open[id] != nil || byID[id] != nil || closed[id] != nil
    }

    /// Every row once, newest created first, as the daemon lists them.
    /// When reads disagree, the newer `updated` wins; on a tie, open, then by id, then closed.
    public var all: [QItem] {
        let ids = Set(open.keys).union(byID.keys).union(closed.keys)
        return ids.compactMap(row).sorted {
            let (a, b) = ($0.created ?? .distantPast, $1.created ?? .distantPast)
            return a != b ? a > b : $0.id > $1.id
        }
    }

    /// Ancestors of a row that are not held, oldest first.
    public func missingAncestors(of id: String) -> [String] {
        guard let row = row(id) else { return [] }
        var ids = row.chainOfRecord ?? []
        if let previous = row.handedOffFrom, !ids.contains(previous) { ids.append(previous) }
        return ids.filter { !holds($0) }
    }

    private static func index(_ rows: [QItem]) -> [String: QItem] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: newer)
    }

    /// `current` unless `candidate` was updated later. Callers pass the preferred copy as `candidate`.
    private static func newer(_ current: QItem?, _ candidate: QItem) -> QItem {
        guard let current else { return candidate }
        let (a, b) = (current.updated ?? .distantPast, candidate.updated ?? .distantPast)
        return a > b ? current : candidate
    }
}

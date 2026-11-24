import Foundation
import RigModel

/// One thing Go to… (⌘K) can jump to.
public struct GoToItem: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case rig, seat, task }
    public var kind: Kind
    /// The rig's, seat's or row's own id.
    public var id: String
    /// What the person types: a rig or seat name, or a task's short id.
    public var title: String
    /// Shown beside it and matched too: a seat's rig, a task's summary.
    public var detail: String

    /// A task that has finished, e.g. one closed today.
    public var isClosed: Bool

    public init(kind: Kind, id: String, title: String, detail: String, isClosed: Bool = false) {
        self.kind = kind
        self.id = id
        self.title = title
        self.detail = detail
        self.isClosed = isClosed
    }

    /// A row as a task: a finished one's outcome leads its summary ("Done · Fix the build").
    public init(task row: QItem) {
        let ended = outcome(row)
        self.init(
            kind: .task, id: row.id, title: shortQItemID(row.id),
            detail: ended.map { "\($0.label) · \(row.summary)" } ?? row.summary,
            isClosed: !workStatus(row).isActive)
    }
}

/// The row to highlight: the one with `id` while it still matches, so rows arriving later don't move the
/// highlight; otherwise the first.
public func goToHighlight(_ id: String?, in matches: [GoToItem]) -> Int {
    id.flatMap { id in matches.firstIndex { $0.id == id } } ?? 0
}

/// The items `query` matches, best first: the title starts with it, then a word in the title does ("sec" in
/// "review-security"), then the title contains it, then the detail does. Ties keep the given order (rigs, seats, tasks).
public func goToMatches(_ query: String, in items: [GoToItem], limit: Int = 12) -> [GoToItem] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return Array(items.prefix(limit)) }
    let scored = items.enumerated().compactMap { index, item -> (score: Int, index: Int, item: GoToItem)? in
        let title = item.title.lowercased()
        let words = title.split(whereSeparator: { "-_. @·/".contains($0) })
        let score: Int? =
            if title.hasPrefix(q) {
                0
            } else if words.contains(where: { $0.hasPrefix(q) }) {
                1
            } else if title.contains(q) {
                2
            } else if item.detail.lowercased().contains(q) {
                3
            } else {
                nil
            }
        return score.map { ($0, index, item) }
    }
    return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.prefix(limit).map(\.item)
}

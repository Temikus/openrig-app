import CoreGraphics

/// What the layout needs to know about a rig. IDs are opaque strings.
public struct LayoutInput: Sendable, Equatable {
    public struct Pod: Sendable, Equatable {
        public var id: String
        /// Seats in spec order; they stack top to bottom in this order.
        public var seatIDs: [String]
        public init(id: String, seatIDs: [String]) {
            self.id = id
            self.seatIDs = seatIDs
        }
    }

    /// A directed seat-to-seat relation that should read left to right.
    public struct Flow: Sendable, Equatable {
        public var source: String
        public var target: String
        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
    }

    public var pods: [Pod]
    public var flows: [Flow]
    /// Measured seat sizes. Only the height is used; missing seats get the default height.
    public var seatSizes: [String: CGSize]

    public init(pods: [Pod], flows: [Flow], seatSizes: [String: CGSize] = [:]) {
        self.pods = pods
        self.flows = flows
        self.seatSizes = seatSizes
    }
}

public struct LayoutMetrics: Sendable, Equatable {
    public var seatWidth: CGFloat = 216
    public var defaultSeatHeight: CGFloat = 96
    public var podPadding: CGFloat = 20
    public var podHeader: CGFloat = 36
    public var seatGap: CGFloat = 14
    /// Horizontal gap between pod columns; wires run through it.
    public var columnGap: CGFloat = 112
    public var podGap: CGFloat = 56
    public var margin: CGFloat = 64
    /// Port height below the seat's top edge (the header's centre line).
    public var portInset: CGFloat = 22

    public init() {}
}

public struct CanvasLayout: Sendable, Equatable {
    public var pods: [String: CGRect]
    public var seats: [String: CGRect]
    public var podColumn: [String: Int]
    public var bounds: CGRect
    public var metrics: LayoutMetrics

    public func outPort(_ seat: String) -> CGPoint {
        guard let r = seats[seat] else { return .zero }
        return CGPoint(x: r.maxX, y: r.minY + metrics.portInset)
    }

    public func inPort(_ seat: String) -> CGPoint {
        guard let r = seats[seat] else { return .zero }
        return CGPoint(x: r.minX, y: r.minY + metrics.portInset)
    }
}

/// Deterministic layered layout: pods become columns ranked by the longest flow path into them,
/// seats stack inside their pod. Cycles are broken by dropping edges that point back in spec order.
public func layoutRig(_ input: LayoutInput, metrics m: LayoutMetrics = LayoutMetrics()) -> CanvasLayout {
    var podOfSeat: [String: Int] = [:]
    for (i, pod) in input.pods.enumerated() {
        for seat in pod.seatIDs { podOfSeat[seat] = i }
    }

    // Pod-level graph, deduplicated, in spec order.
    var successors = Array(repeating: [Int](), count: input.pods.count)
    for flow in input.flows {
        guard let s = podOfSeat[flow.source], let t = podOfSeat[flow.target], s != t,
            !successors[s].contains(t)
        else { continue }
        successors[s].append(t)
    }
    for i in successors.indices { successors[i].sort() }

    let rank = longestPathRanks(successors)
    let columns = Dictionary(grouping: input.pods.indices, by: { rank[$0] })
    let columnCount = (columns.keys.max() ?? -1) + 1

    func seatHeight(_ id: String) -> CGFloat {
        input.seatSizes[id].map { max($0.height, 24) } ?? m.defaultSeatHeight
    }
    func podHeight(_ pod: LayoutInput.Pod) -> CGFloat {
        let seats = pod.seatIDs.map(seatHeight).reduce(0, +)
        let gaps = CGFloat(max(pod.seatIDs.count - 1, 0)) * m.seatGap
        return m.podHeader + seats + gaps + m.podPadding
    }

    let podWidth = m.seatWidth + 2 * m.podPadding
    let columnHeights = (0..<columnCount).map { c in
        let pods = columns[c, default: []]
        return pods.map { podHeight(input.pods[$0]) }.reduce(0, +) + CGFloat(max(pods.count - 1, 0)) * m.podGap
    }
    let tallest = columnHeights.max() ?? 0

    var pods: [String: CGRect] = [:]
    var seats: [String: CGRect] = [:]
    var podColumn: [String: Int] = [:]
    for c in 0..<columnCount {
        let x = m.margin + CGFloat(c) * (podWidth + m.columnGap)
        var y = m.margin + ((tallest - columnHeights[c]) / 2).rounded()
        for i in columns[c, default: []].sorted() {
            let pod = input.pods[i]
            let frame = CGRect(x: x, y: y, width: podWidth, height: podHeight(pod))
            pods[pod.id] = frame
            podColumn[pod.id] = c
            var seatY = y + m.podHeader
            for seat in pod.seatIDs {
                let h = seatHeight(seat)
                seats[seat] = CGRect(x: x + m.podPadding, y: seatY, width: m.seatWidth, height: h)
                seatY += h + m.seatGap
            }
            y = frame.maxY + m.podGap
        }
    }

    let width = 2 * m.margin + CGFloat(columnCount) * podWidth + CGFloat(max(columnCount - 1, 0)) * m.columnGap
    let bounds = CGRect(x: 0, y: 0, width: max(width, 2 * m.margin), height: tallest + 2 * m.margin)
    return CanvasLayout(pods: pods, seats: seats, podColumn: podColumn, bounds: bounds, metrics: m)
}

/// Rank = longest path from any source. Back edges found by DFS in index order are ignored.
func longestPathRanks(_ successors: [[Int]]) -> [Int] {
    let n = successors.count
    var state = Array(repeating: 0, count: n)  // 0 new, 1 on stack, 2 done
    var order: [Int] = []
    var forward = Array(repeating: [Int](), count: n)

    func visit(_ v: Int) {
        state[v] = 1
        for w in successors[v] {
            if state[w] == 1 { continue }  // back edge: breaks the cycle
            forward[v].append(w)
            if state[w] == 0 { visit(w) }
        }
        state[v] = 2
        order.append(v)
    }
    for v in 0..<n where state[v] == 0 { visit(v) }

    var rank = Array(repeating: 0, count: n)
    for v in order.reversed() {
        for w in forward[v] { rank[w] = max(rank[w], rank[v] + 1) }
    }
    return rank
}

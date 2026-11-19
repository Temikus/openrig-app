import CoreGraphics
import HeapModule

public enum WireKind: String, Sendable, Hashable, CaseIterable {
    // Spec edges
    case delegates, observes, related
    // Work (M2)
    case inFlight, needsYou, next, past
}

public struct WireRequest: Sendable, Hashable {
    public var id: String
    public var source: String
    public var target: String
    public var kind: WireKind

    public init(id: String, source: String, target: String, kind: WireKind) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
    }
}

public struct Wire: Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var target: String
    public var kind: WireKind
    /// Orthogonal polyline from the source's out port to the target's in port, corners not rounded.
    public var points: [CGPoint]

    public var segments: [(CGPoint, CGPoint)] { Array(zip(points, points.dropFirst())) }
    public var bends: Int { max(points.count - 2, 0) }
}

public struct RouteResult: Sendable, Equatable {
    public var wires: [Wire]
    /// Points where a trunk shared by one source's wires branches.
    public var junctions: [CGPoint]

    public init(wires: [Wire] = [], junctions: [CGPoint] = []) {
        self.wires = wires
        self.junctions = junctions
    }
}

public struct RouterOptions: Sendable {
    /// Free space kept around each seat.
    public var clearance: CGFloat = 6
    /// Straight run out of an out port and into an in port.
    public var stub: CGFloat = 16
    public var bendPenalty: CGFloat = 40
    /// Cost factor for running along a segment this source already uses, so fan-outs share a trunk.
    public var trunkDiscount: CGFloat = 0.35
    /// Cost factor for vertical runs outside the channels between pod columns.
    public var offChannelVertical: CGFloat = 3
    /// Cost factor for running through a pod that is neither the source's nor the target's.
    public var foreignPod: CGFloat = 2.5
    public var laneSpacing: CGFloat = 8

    public init() {}
}

/// Corner radius for a rounded orthogonal path: never more than half of either neighbouring segment.
public func cornerRadius(previous: CGFloat, next: CGFloat, max r: CGFloat = 10) -> CGFloat {
    min(r, previous / 2, next / 2)
}

/// Routes wires on a sparse orthogonal grid built from channel lines, ports and seat gaps.
/// Each wire is a Dijkstra search costing length plus a penalty per bend. Wires from one source
/// share segments (trunks); different sources on the same line get separate lanes.
public func route(_ layout: CanvasLayout, _ requests: [WireRequest], options o: RouterOptions = RouterOptions())
    -> RouteResult
{
    let grid = RoutingGrid(layout: layout, options: o)
    func podFrame(of seat: String) -> CGRect? {
        layout.pods.values.first { $0.contains(layout.seats[seat]!) }
    }
    // Route in a fixed order so results don't depend on request order.
    let ordered = requests.filter { layout.seats[$0.source] != nil && layout.seats[$0.target] != nil }
        .sorted { a, b in
            let (sa, sb) = (layout.outPort(a.source), layout.outPort(b.source))
            if sa.y != sb.y { return sa.y < sb.y }
            if sa.x != sb.x { return sa.x < sb.x }
            if a.source != b.source { return a.source < b.source }
            let (ta, tb) = (layout.inPort(a.target), layout.inPort(b.target))
            if ta.y != tb.y { return ta.y < tb.y }
            if ta.x != tb.x { return ta.x < tb.x }
            return a.id < b.id
        }

    var usedBySource: [String: Set<Int>] = [:]
    var routed: [String: Wire] = [:]
    for request in ordered {
        let start = layout.outPort(request.source)
        let end = layout.inPort(request.target)
        var used = usedBySource[request.source, default: []]
        let points: [CGPoint]
        if let path = grid.shortestPath(
            from: CGPoint(x: start.x + o.stub, y: start.y),
            to: CGPoint(x: end.x - o.stub, y: end.y),
            discounted: used,
            avoiding: layout.pods.keys.sorted().compactMap { key -> CGRect? in
                let frame = layout.pods[key]!
                return frame == podFrame(of: request.source) || frame == podFrame(of: request.target) ? nil : frame
            }
        ) {
            used.formUnion(path.edges)
            points = [start] + path.points + [end]
        } else {
            // No grid path (shouldn't happen with channels on every side): fall back to a plain dogleg.
            let midX = (start.x + end.x) / 2
            points = [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
        }
        usedBySource[request.source] = used
        routed[request.id] = Wire(
            id: request.id, source: request.source, target: request.target, kind: request.kind,
            points: simplify(points))
    }

    var wires = ordered.compactMap { routed[$0.id] }
    assignLanes(&wires, spacing: o.laneSpacing)
    let junctions = thinned(findJunctions(wires), within: o.laneSpacing)
    let byID = Dictionary(uniqueKeysWithValues: wires.map { ($0.id, $0) })
    var seen = Set<String>()
    let output = requests.compactMap { r -> Wire? in seen.insert(r.id).inserted ? byID[r.id] : nil }
    return RouteResult(wires: output, junctions: junctions)
}

// MARK: - Grid

struct RoutingGrid {
    let xs: [CGFloat]
    let ys: [CGFloat]
    let channelXs: Set<CGFloat>
    let obstacles: [CGRect]
    let options: RouterOptions
    let valid: [Bool]

    init(layout: CanvasLayout, options o: RouterOptions) {
        let m = layout.metrics
        var xs = Set<CGFloat>()
        var ys = Set<CGFloat>()
        var channels = Set<CGFloat>()
        for seat in layout.seats.keys.sorted() {
            let r = layout.seats[seat]!
            xs.formUnion([r.maxX + o.stub, r.minX - o.stub])
            ys.formUnion([r.minY + m.portInset, r.minY - m.seatGap / 2, r.maxY + m.seatGap / 2])
        }
        for pod in layout.pods.keys.sorted() {
            let p = layout.pods[pod]!
            let channelLeft = p.minX - m.columnGap / 2
            let channelRight = p.maxX + m.columnGap / 2
            channels.formUnion([channelLeft, channelRight])
            xs.formUnion([channelLeft, channelRight, p.minX + m.podPadding / 2, p.maxX - m.podPadding / 2])
            ys.formUnion([p.minY - m.podGap / 2, p.maxY + m.podGap / 2, p.minY + m.podHeader / 2])
        }
        let b = layout.bounds
        channels.formUnion([b.minX + m.margin / 2, b.maxX - m.margin / 2])
        xs.formUnion([b.minX + m.margin / 2, b.maxX - m.margin / 2])
        ys.formUnion([b.minY + m.margin / 2, b.maxY - m.margin / 2])

        self.xs = xs.sorted()
        self.ys = ys.sorted()
        self.channelXs = channels
        self.options = o
        let obstacles = layout.seats.keys.sorted().map { layout.seats[$0]!.insetBy(dx: -o.clearance, dy: -o.clearance) }
        self.obstacles = obstacles
        var valid: [Bool] = []
        valid.reserveCapacity(self.xs.count * self.ys.count)
        for y in self.ys {
            for x in self.xs {
                valid.append(!obstacles.contains { $0.minX < x && x < $0.maxX && $0.minY < y && y < $0.maxY })
            }
        }
        self.valid = valid
    }

    var nx: Int { xs.count }
    func point(_ i: Int) -> CGPoint { CGPoint(x: xs[i % nx], y: ys[i / nx]) }

    func index(of p: CGPoint) -> Int? {
        guard let xi = xs.firstIndex(of: p.x), let yi = ys.firstIndex(of: p.y) else { return nil }
        let i = yi * nx + xi
        return valid[i] ? i : nil
    }

    /// Direction 0 east, 1 west, 2 north (up), 3 south.
    func neighbor(_ i: Int, _ dir: Int) -> Int? {
        let xi = i % nx
        let yi = i / nx
        let j: Int
        switch dir {
        case 0: guard xi + 1 < nx else { return nil }; j = i + 1
        case 1: guard xi > 0 else { return nil }; j = i - 1
        case 2: guard yi > 0 else { return nil }; j = i - nx
        default: guard yi + 1 < ys.count else { return nil }; j = i + nx
        }
        guard valid[j], isClear(point(i), point(j)) else { return nil }
        return j
    }

    func isClear(_ a: CGPoint, _ b: CGPoint) -> Bool {
        if a.y == b.y {
            let (lo, hi) = (min(a.x, b.x), max(a.x, b.x))
            return !obstacles.contains { $0.minY < a.y && a.y < $0.maxY && $0.minX < hi && lo < $0.maxX }
        }
        let (lo, hi) = (min(a.y, b.y), max(a.y, b.y))
        return !obstacles.contains { $0.minX < a.x && a.x < $0.maxX && $0.minY < hi && lo < $0.maxY }
    }

    /// The segment runs through the rect's interior (touching the border doesn't count).
    func crosses(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        if a.y == b.y {
            return r.minY < a.y && a.y < r.maxY && min(a.x, b.x) < r.maxX && r.minX < max(a.x, b.x)
        }
        return r.minX < a.x && a.x < r.maxX && min(a.y, b.y) < r.maxY && r.minY < max(a.y, b.y)
    }

    static func edgeKey(_ a: Int, _ b: Int) -> Int { min(a, b) << 32 | max(a, b) }

    struct Path {
        var points: [CGPoint]
        var edges: Set<Int>
    }

    private struct Entry: Comparable {
        var cost: CGFloat
        var state: Int
        static func < (l: Entry, r: Entry) -> Bool { (l.cost, l.state) < (r.cost, r.state) }
    }

    /// Leaves `start` heading east and must arrive at `goal` able to continue east.
    func shortestPath(from start: CGPoint, to goal: CGPoint, discounted: Set<Int>, avoiding pods: [CGRect]) -> Path? {
        guard let s = index(of: start), let g = index(of: goal) else { return nil }
        let opposite = [1, 0, 3, 2]
        var dist = [CGFloat](repeating: .infinity, count: valid.count * 4)
        var prev = [Int](repeating: -1, count: valid.count * 4)
        var heap = Heap<Entry>()
        dist[s * 4] = 0
        heap.insert(Entry(cost: 0, state: s * 4))

        var best: (cost: CGFloat, state: Int)?
        while let e = heap.popMin() {
            guard e.cost == dist[e.state] else { continue }
            if let b = best, e.cost >= b.cost { break }
            let (p, dir) = (e.state / 4, e.state % 4)
            if p == g, dir != 1 {
                let total = e.cost + (dir == 0 ? 0 : options.bendPenalty)
                if best == nil || total < best!.cost { best = (total, e.state) }
                continue
            }
            for d in 0..<4 where d != opposite[dir] {
                guard let q = neighbor(p, d) else { continue }
                let a = point(p)
                let b = point(q)
                var length = abs(a.x - b.x) + abs(a.y - b.y)
                if d >= 2 && !channelXs.contains(a.x) { length *= options.offChannelVertical }
                if pods.contains(where: { crosses(a, b, $0) }) { length *= options.foreignPod }
                if discounted.contains(Self.edgeKey(p, q)) { length *= options.trunkDiscount }
                let cost = e.cost + length + (d == dir ? 0 : options.bendPenalty)
                let next = q * 4 + d
                if cost < dist[next] {
                    dist[next] = cost
                    prev[next] = e.state
                    heap.insert(Entry(cost: cost, state: next))
                }
            }
        }
        guard let end = best?.state else { return nil }
        var states = [end]
        while let last = states.last, prev[last] >= 0 { states.append(prev[last]) }
        let indices = states.reversed().map { $0 / 4 }
        var edges = Set<Int>()
        for (a, b) in zip(indices, indices.dropFirst()) { edges.insert(Self.edgeKey(a, b)) }
        return Path(points: indices.map(point), edges: edges)
    }
}

// MARK: - Post-processing

/// Drops repeated points and merges collinear runs.
func simplify(_ points: [CGPoint]) -> [CGPoint] {
    var out: [CGPoint] = []
    for p in points {
        if let last = out.last, last == p { continue }
        if out.count >= 2 {
            let a = out[out.count - 2]
            let b = out[out.count - 1]
            if (a.x == b.x && b.x == p.x) || (a.y == b.y && b.y == p.y) {
                out[out.count - 1] = p
                continue
            }
        }
        out.append(p)
    }
    return out
}

private struct LineKey: Hashable {
    var vertical: Bool
    var at: CGFloat
}

/// Moves interior segments that share a line with another source's segment onto parallel lanes.
/// First and last segments stay put so wires still meet their ports.
func assignLanes(_ wires: inout [Wire], spacing: CGFloat) {
    struct Piece {
        var wire: Int
        var segment: Int
        var lo: CGFloat
        var hi: CGFloat
    }
    var groups: [LineKey: [Piece]] = [:]
    for (wi, w) in wires.enumerated() where w.points.count >= 4 {
        for k in 1..<(w.points.count - 2) {
            let a = w.points[k]
            let b = w.points[k + 1]
            let vertical = a.x == b.x
            let key = LineKey(vertical: vertical, at: vertical ? a.x : a.y)
            let (lo, hi) = vertical ? (min(a.y, b.y), max(a.y, b.y)) : (min(a.x, b.x), max(a.x, b.x))
            groups[key, default: []].append(Piece(wire: wi, segment: k, lo: lo, hi: hi))
        }
    }

    func offset(_ lane: Int) -> CGFloat {
        lane == 0 ? 0 : (lane % 2 == 1 ? 1 : -1) * spacing * CGFloat((lane + 1) / 2)
    }

    var shifts: [(wire: Int, segment: Int, vertical: Bool, by: CGFloat)] = []
    for key in groups.keys.sorted(by: { ($0.vertical ? 1 : 0, $0.at) < ($1.vertical ? 1 : 0, $1.at) }) {
        let pieces = groups[key]!
        let bySource = Dictionary(grouping: pieces, by: { wires[$0.wire].source })
        guard bySource.count > 1 else { continue }
        let sources = bySource.keys.sorted { a, b in
            let la = bySource[a]!.map(\.lo).min()!
            let lb = bySource[b]!.map(\.lo).min()!
            return la == lb ? a < b : la < lb
        }
        var lanes: [(lane: Int, pieces: [Piece])] = []
        for source in sources {
            let mine = bySource[source]!
            var lane = 0
            while lanes.contains(where: { other in
                other.lane == lane
                    && other.pieces.contains { p in mine.contains { q in max(p.lo, q.lo) < min(p.hi, q.hi) } }
            }) {
                lane += 1
            }
            lanes.append((lane, mine))
            guard lane != 0 else { continue }
            for piece in mine {
                shifts.append((piece.wire, piece.segment, key.vertical, offset(lane)))
            }
        }
    }
    for s in shifts {
        for k in [s.segment, s.segment + 1] {
            if s.vertical { wires[s.wire].points[k].x += s.by } else { wires[s.wire].points[k].y += s.by }
        }
    }
    for i in wires.indices { wires[i].points = simplify(wires[i].points) }
}

func sign(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : (v < 0 ? -1 : 0) }

private struct PointKey: Hashable, Comparable {
    var x: CGFloat
    var y: CGFloat
    static func < (l: PointKey, r: PointKey) -> Bool { (l.y, l.x) < (r.y, r.x) }
}

/// Points where a wire leaves a path it shared with another wire from the same source.
func findJunctions(_ wires: [Wire]) -> [CGPoint] {
    func onSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
        (a.x == b.x && p.x == a.x && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y))
            || (a.y == b.y && p.y == a.y && min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x))
    }
    func runs(_ w: Wire, from p: CGPoint, toward q: CGPoint) -> Bool {
        // A one-point step from p toward q lies on w.
        let step = CGPoint(x: p.x + sign(q.x - p.x), y: p.y + sign(q.y - p.y))
        return w.segments.contains { onSegment(p, $0.0, $0.1) && onSegment(step, $0.0, $0.1) }
    }

    var found = Set<PointKey>()
    let bySource = Dictionary(grouping: wires, by: \.source)
    for group in bySource.values where group.count > 1 {
        for w in group {
            for k in 1..<max(w.points.count - 1, 1) {
                let v = w.points[k]
                for other in group where other.id != w.id {
                    if runs(other, from: v, toward: w.points[k - 1]) && !runs(other, from: v, toward: w.points[k + 1]) {
                        found.insert(PointKey(x: v.x, y: v.y))
                    }
                }
            }
            // A wire can also leave a trunk partway along a straight segment of its own.
            for other in group where other.id != w.id {
                for v in other.points.dropFirst().dropLast() {
                    guard let k = w.segments.firstIndex(where: { onSegment(v, $0.0, $0.1) }),
                        v != w.points[k + 1], v != w.points[k]
                    else { continue }
                    if runs(other, from: v, toward: w.points[k]) && !runs(other, from: v, toward: w.points[k + 1]) {
                        found.insert(PointKey(x: v.x, y: v.y))
                    }
                }
            }
        }
    }
    return found.sorted().map { CGPoint(x: $0.x, y: $0.y) }
}

/// Drops each junction within `gap` of one already kept, so lanes branching side by side show one dot, not a clump.
public func thinned(_ points: [CGPoint], within gap: CGFloat) -> [CGPoint] {
    var kept: [CGPoint] = []
    for p in points where !kept.contains(where: { abs($0.x - p.x) <= gap && abs($0.y - p.y) <= gap }) {
        kept.append(p)
    }
    return kept
}

/// The polyline as a path with rounded corners (quadratic curves through each corner point).
public func roundedPath(_ points: [CGPoint], radius: CGFloat = 10) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in points.indices.dropFirst().dropLast() {
        let (a, b, c) = (points[i - 1], points[i], points[i + 1])
        let l1 = abs(b.x - a.x) + abs(b.y - a.y)
        let l2 = abs(c.x - b.x) + abs(c.y - b.y)
        let r = cornerRadius(previous: l1, next: l2, max: radius)
        let u = CGPoint(x: sign(b.x - a.x), y: sign(b.y - a.y))
        let v = CGPoint(x: sign(c.x - b.x), y: sign(c.y - b.y))
        path.addLine(to: CGPoint(x: b.x - u.x * r, y: b.y - u.y * r))
        path.addQuadCurve(to: CGPoint(x: b.x + v.x * r, y: b.y + v.y * r), control: b)
    }
    if let last = points.last, points.count > 1 { path.addLine(to: last) }
    return path
}

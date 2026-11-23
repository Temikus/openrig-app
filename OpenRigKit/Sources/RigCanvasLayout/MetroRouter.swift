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
    /// Wires of one kind joined by a shared source or target; they share trunks, lanes and junctions.
    public var bundle: String
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
    /// Extra length (bends at `bendPenalty`) a wire may take to go around another instead of crossing it, per crossing
    /// removed.
    public var detourPerCrossing: CGFloat = 480
    /// While looking for that detour, cost of each grid point the crossed wire passes through.
    public var crossedPointPenalty: CGFloat = 200

    public init() {}
}

/// Corner radius for a rounded orthogonal path: never more than half of either neighbouring segment.
public func cornerRadius(previous: CGFloat, next: CGFloat, max r: CGFloat = 10) -> CGFloat {
    min(r, previous / 2, next / 2)
}

/// Bundles requests: the same kind sharing a source (a fan-out) or a target (a fan-in), transitively, when every source
/// in the group reaches every target. Drawn as one line where they overlap, so two builders watching the same
/// reviewers read as one watch line, not two.
/// Keyed by request id; each bundle is named by its smallest id.
func bundles(_ requests: [WireRequest]) -> [String: String] {
    var parent: [String: String] = [:]
    for r in requests { parent[r.id] = r.id }
    func find(_ x: String) -> String {
        var x = x
        while let up = parent[x], up != x { x = up }
        return x
    }
    var first: [String: String] = [:]
    for r in requests {
        for end in ["s>\(r.kind.rawValue)>\(r.source)", "t>\(r.kind.rawValue)>\(r.target)"] {
            guard let other = first[end] else {
                first[end] = r.id
                continue
            }
            let (a, b) = (find(other), find(r.id))
            if a != b { parent[max(a, b)] = min(a, b) }
        }
    }
    var out: [String: String] = parent.keys.reduce(into: [:]) { $0[$1] = find($1) }
    // A shared trunk implies every source reaches every target. Where that's false (a→p, b→p, b→q would suggest
    // a→q), fall back to one bundle per source and kind, the plain fan-out.
    for members in Dictionary(grouping: requests, by: { out[$0.id]! }).values {
        let pairs = Set(members.map { "\($0.source)>\($0.target)" })
        let sources = Set(members.map(\.source)), targets = Set(members.map(\.target))
        guard pairs.count != sources.count * targets.count else { continue }
        let bySource = Dictionary(grouping: members, by: \.source)
        for group in bySource.values {
            let name = group.map(\.id).min()!
            for r in group { out[r.id] = name }
        }
    }
    return out
}

/// Routes wires on a sparse orthogonal grid built from channel lines, ports and seat gaps.
/// Each wire is a Dijkstra search costing length plus a penalty per bend. Wires of one bundle
/// share segments (trunks); different bundles on the same line get separate lanes.
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

    let bundleOf = bundles(ordered)
    let pods = layout.pods.keys.sorted().map { layout.pods[$0]! }
    var paths: [String: RoutedPath] = [:]

    /// Routes one bundle's wires in order; later ones share the earlier ones' trunk.
    func routeBundle(_ bundle: String, avoiding avoid: Set<Int> = []) -> [String: RoutedPath] {
        var used = Set<Int>()
        var out: [String: RoutedPath] = [:]
        for request in ordered where bundleOf[request.id] == bundle {
            let start = layout.outPort(request.source)
            let end = layout.inPort(request.target)
            let own = [podFrame(of: request.source), podFrame(of: request.target)]
            if let path = grid.shortestPath(
                from: CGPoint(x: start.x + o.stub, y: start.y),
                to: CGPoint(x: end.x - o.stub, y: end.y),
                discounted: used,
                avoiding: pods.filter { !own.contains($0) },
                crossedPoints: avoid
            ) {
                used.formUnion(path.edges)
                out[request.id] = RoutedPath(points: simplify([start] + path.points + [end]), vertices: path.vertices)
            } else {
                // No grid path (shouldn't happen with channels on every side): fall back to a plain dogleg.
                let midX = (start.x + end.x) / 2
                let points = [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
                out[request.id] = RoutedPath(points: simplify(points), vertices: [])
            }
        }
        return out
    }

    func laidOut(_ paths: [String: RoutedPath]) -> [Wire] {
        var wires = ordered.compactMap { r -> Wire? in
            paths[r.id].map {
                Wire(
                    id: r.id, source: r.source, target: r.target, kind: r.kind, bundle: bundleOf[r.id] ?? r.id,
                    points: $0.points)
            }
        }
        assignLanes(&wires, spacing: o.laneSpacing)
        staggerInPorts(&wires, spacing: o.laneSpacing)
        return wires
    }

    var bundleOrder: [String] = []
    for r in ordered where !bundleOrder.contains(bundleOf[r.id]!) { bundleOrder.append(bundleOf[r.id]!) }
    for bundle in bundleOrder { paths.merge(routeBundle(bundle)) { $1 } }
    var wires = laidOut(paths)

    // Detours. Two wires whose ends interleave along a shared line cross however their lanes are ordered. Re-route a
    // bundle that crosses another around it, and keep the new route if it removes crossings for a short enough detour.
    // Work wires come and go, so they detour before spec wires do; within each, the last routed goes first.
    var crossings = crossingCount(wires)
    let isWork = { (b: String) in ordered.contains { bundleOf[$0.id] == b && $0.kind.isWork } }
    let rerouteOrder = bundleOrder.reversed().filter(isWork) + bundleOrder.reversed().filter { !isWork($0) }
    for bundle in rerouteOrder where crossings > 0 {
        let mine = wires.filter { $0.bundle == bundle }
        let crossed = wires.filter { other in
            other.bundle != bundle && other.kind != .observes && mine.contains { crossingCount($0, other) > 0 }
        }
        guard !crossed.isEmpty else { continue }
        var candidate = paths
        candidate.merge(routeBundle(bundle, avoiding: Set(crossed.flatMap { paths[$0.id]!.vertices }))) { $1 }
        let next = laidOut(candidate)
        let remaining = crossingCount(next)
        func length(_ p: [String: RoutedPath]) -> CGFloat {
            mine.reduce(0) { sum, w in
                let points = p[w.id]!.points
                return sum + polylineLength(points) + CGFloat(max(points.count - 2, 0)) * o.bendPenalty
            }
        }
        guard remaining < crossings,
            length(candidate) - length(paths) <= o.detourPerCrossing * CGFloat(crossings - remaining)
        else { continue }
        paths = candidate
        wires = next
        crossings = remaining
    }

    let junctions = thinned(findJunctions(wires), within: o.laneSpacing)
    let byID = Dictionary(uniqueKeysWithValues: wires.map { ($0.id, $0) })
    var seen = Set<String>()
    let output = requests.compactMap { r -> Wire? in seen.insert(r.id).inserted ? byID[r.id] : nil }
    return RouteResult(wires: output, junctions: junctions)
}

extension WireKind {
    var isWork: Bool { [.inFlight, .needsYou, .next, .past].contains(self) }
}

struct RoutedPath {
    /// Port to port, corners not rounded, before lanes.
    var points: [CGPoint]
    /// Grid points the search passed through.
    var vertices: Set<Int>
}

func polylineLength(_ points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).reduce(0) { $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y) }
}

/// Places where a segment of one wire passes through the inside of a perpendicular segment of the other.
func crossingCount(_ a: Wire, _ b: Wire) -> Int {
    var n = 0
    for (p, q) in a.segments {
        for (r, s) in b.segments {
            let (h, v) = p.y == q.y ? ((p, q), (r, s)) : ((r, s), (p, q))
            guard h.0.y == h.1.y, v.0.x == v.1.x, h.0 != h.1, v.0 != v.1 else { continue }
            let (x, y) = (v.0.x, h.0.y)
            if min(h.0.x, h.1.x) < x, x < max(h.0.x, h.1.x), min(v.0.y, v.1.y) < y, y < max(v.0.y, v.1.y) { n += 1 }
        }
    }
    return n
}

/// Crossings between wires of different bundles. Wires of one bundle share trunks, and watch lines draw faint as
/// context, so neither counts.
func crossingCount(_ wires: [Wire]) -> Int {
    let counted = wires.filter { $0.kind != .observes }
    var n = 0
    for (i, a) in counted.enumerated() {
        for b in counted[(i + 1)...] where a.bundle != b.bundle { n += crossingCount(a, b) }
    }
    return n
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
        var vertices: Set<Int>
    }

    private struct Entry: Comparable {
        var cost: CGFloat
        var state: Int
        static func < (l: Entry, r: Entry) -> Bool { (l.cost, l.state) < (r.cost, r.state) }
    }

    /// Leaves `start` heading east and must arrive at `goal` able to continue east. Each of `crossedPoints` on the way
    /// costs `crossedPointPenalty`.
    func shortestPath(
        from start: CGPoint, to goal: CGPoint, discounted: Set<Int>, avoiding pods: [CGRect],
        crossedPoints: Set<Int> = []
    ) -> Path? {
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
                var cost = e.cost + length + (d == dir ? 0 : options.bendPenalty)
                if q != g, crossedPoints.contains(q) { cost += options.crossedPointPenalty }
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
        return Path(points: indices.map(point), edges: edges, vertices: Set(indices))
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
/// Spreads different bundles that share a line into lanes `spacing` apart, centred on the line. Bundles that
/// overlap are ordered to cross each other's turns as little as possible: a bundle whose runs leave toward the
/// low side (left or up) goes on that side.
func assignLanes(_ wires: inout [Wire], spacing: CGFloat) {
    /// Where a neighbouring segment leaves the piece's line, and toward which side (-1 low, +1 high).
    struct Turn {
        var at: CGFloat
        var side: CGFloat
    }
    struct Piece {
        var wire: Int
        var segment: Int
        var lo: CGFloat
        var hi: CGFloat
        var turns: [Turn]
    }
    var groups: [LineKey: [Piece]] = [:]
    for (wi, w) in wires.enumerated() where w.points.count >= 4 {
        for k in 1..<(w.points.count - 2) {
            let (before, a, b, after) = (w.points[k - 1], w.points[k], w.points[k + 1], w.points[k + 2])
            let vertical = a.x == b.x
            let key = LineKey(vertical: vertical, at: vertical ? a.x : a.y)
            let (lo, hi) = vertical ? (min(a.y, b.y), max(a.y, b.y)) : (min(a.x, b.x), max(a.x, b.x))
            let turns =
                vertical
                ? [Turn(at: a.y, side: sign(before.x - a.x)), Turn(at: b.y, side: sign(after.x - b.x))]
                : [Turn(at: a.x, side: sign(before.y - a.y)), Turn(at: b.x, side: sign(after.y - b.y))]
            groups[key, default: []].append(Piece(wire: wi, segment: k, lo: lo, hi: hi, turns: turns))
        }
    }

    func overlaps(_ a: [Piece], _ b: [Piece]) -> Bool {
        a.contains { p in b.contains { q in max(p.lo, q.lo) < min(p.hi, q.hi) } }
    }
    /// Crossings when `low` sits on the low side of `high`: turns of one that reach across the other's span.
    func crossings(low: [Piece], high: [Piece]) -> Int {
        func inside(_ at: CGFloat, _ pieces: [Piece]) -> Bool { pieces.contains { $0.lo < at && at < $0.hi } }
        let fromHigh = high.flatMap(\.turns).filter { $0.side < 0 && inside($0.at, low) }.count
        let fromLow = low.flatMap(\.turns).filter { $0.side > 0 && inside($0.at, high) }.count
        return fromHigh + fromLow
    }
    func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i in
            permutations(Array(items[..<i] + items[(i + 1)...])).map { [items[i]] + $0 }
        }
    }

    var shifts: [(wire: Int, segment: Int, vertical: Bool, by: CGFloat)] = []
    for key in groups.keys.sorted(by: { ($0.vertical ? 1 : 0, $0.at) < ($1.vertical ? 1 : 0, $1.at) }) {
        let byBundle = Dictionary(grouping: groups[key]!, by: { wires[$0.wire].bundle })
        guard byBundle.count > 1 else { continue }
        // Clusters of bundles that overlap along the line, directly or through another bundle.
        var clusters: [[String]] = []
        for bundle in byBundle.keys.sorted() {
            let touching = clusters.indices.filter { i in
                clusters[i].contains { overlaps(byBundle[$0]!, byBundle[bundle]!) }
            }
            let merged = touching.flatMap { clusters[$0] } + [bundle]
            clusters = clusters.indices.filter { !touching.contains($0) }.map { clusters[$0] } + [merged.sorted()]
        }
        for cluster in clusters where cluster.count > 1 {
            // Few bundles meet on one line; past six, keep name order rather than try every order.
            let candidates = cluster.count <= 6 ? permutations(cluster) : [cluster]
            let order = candidates.min { a, b in
                func cost(_ o: [String]) -> Int {
                    o.indices.flatMap { i in o.indices.filter { $0 > i }.map { (i, $0) } }
                        .reduce(0) { $0 + crossings(low: byBundle[o[$1.0]]!, high: byBundle[o[$1.1]]!) }
                }
                return cost(a) < cost(b)
            }!
            for (i, bundle) in order.enumerated() {
                let by = (CGFloat(i) - CGFloat(order.count - 1) / 2) * spacing
                for piece in byBundle[bundle]! { shifts.append((piece.wire, piece.segment, key.vertical, by)) }
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

/// Where several bundles reach one seat, each enters `spacing` below the previous, so none hides under another's
/// final run. The most prominent kind keeps the port itself.
func staggerInPorts(_ wires: inout [Wire], spacing: CGFloat) {
    let prominence: [WireKind] = [.needsYou, .inFlight, .next, .delegates, .past, .related, .observes]
    let byTarget = Dictionary(grouping: wires.indices, by: { wires[$0].target })
    for target in byTarget.keys.sorted() {
        let indices = byTarget[target]!
        let slots = Set(indices.map { wires[$0].bundle }).sorted { a, b in
            func rank(_ bundle: String) -> Int {
                indices.filter { wires[$0].bundle == bundle }
                    .map { prominence.firstIndex(of: wires[$0].kind) ?? prominence.count }.min()!
            }
            return (rank(a), a) < (rank(b), b)
        }
        guard slots.count > 1 else { continue }
        for i in indices {
            let slot = slots.firstIndex(of: wires[i].bundle)!
            let n = wires[i].points.count
            // Moves the final run down along the vertical before it. A straight wire has none to stretch, and one that
            // climbs into the port by no more than the shift would reverse or fold that vertical, so both stay put.
            let shift = CGFloat(slot) * spacing
            guard slot > 0, n >= 3, wires[i].points[n - 3].x == wires[i].points[n - 2].x,
                wires[i].points[n - 3].y - wires[i].points[n - 2].y < -0.5
                    || wires[i].points[n - 3].y - wires[i].points[n - 2].y > shift
            else { continue }
            wires[i].points[n - 1].y += shift
            wires[i].points[n - 2].y += shift
            wires[i].points = simplify(wires[i].points)
        }
    }
}

func sign(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : (v < 0 ? -1 : 0) }

private struct PointKey: Hashable, Comparable {
    var x: CGFloat
    var y: CGFloat
    static func < (l: PointKey, r: PointKey) -> Bool { (l.y, l.x) < (r.y, r.x) }
}

/// Points where a wire leaves a path it shared with another wire of its bundle.
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
    let byBundle = Dictionary(grouping: wires, by: \.bundle)
    for group in byBundle.values where group.count > 1 {
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

/// The polyline as a path with rounded corners (quadratic curves through each corner point). Corners at `sharp` points
/// stay square: a branch leaving a trunk at a junction turns at the dot, rather than curving away from it.
public func roundedPath(_ points: [CGPoint], radius: CGFloat = 10, sharp: Set<CGPoint> = []) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in points.indices.dropFirst().dropLast() {
        let (a, b, c) = (points[i - 1], points[i], points[i + 1])
        let l1 = abs(b.x - a.x) + abs(b.y - a.y)
        let l2 = abs(c.x - b.x) + abs(c.y - b.y)
        let r = sharp.contains(b) ? 0 : cornerRadius(previous: l1, next: l2, max: radius)
        let u = CGPoint(x: sign(b.x - a.x), y: sign(b.y - a.y))
        let v = CGPoint(x: sign(c.x - b.x), y: sign(c.y - b.y))
        path.addLine(to: CGPoint(x: b.x - u.x * r, y: b.y - u.y * r))
        path.addQuadCurve(to: CGPoint(x: b.x + v.x * r, y: b.y + v.y * r), control: b)
    }
    if let last = points.last, points.count > 1 { path.addLine(to: last) }
    return path
}

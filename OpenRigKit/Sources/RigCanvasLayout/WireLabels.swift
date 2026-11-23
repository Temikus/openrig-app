import CoreGraphics

/// A label to place on a routed wire, at its drawn size.
public struct WireLabel: Sendable, Equatable {
    /// The widest a label draws. Wider, it finds no clear spot beside a wire in the 112 pt gap between columns, so the
    /// chip cuts its text to fit.
    public static let maxWidth: CGFloat = 120

    public var wireID: String
    public var size: CGSize

    public init(wireID: String, size: CGSize) {
        self.wireID = wireID
        self.size = CGSize(width: min(size.width, Self.maxWidth), height: size.height)
    }
}

public struct LabelPlacement: Sendable, Equatable {
    /// Each label's box in canvas coordinates, keyed by wire id.
    public var frames: [String: CGRect]
    /// The layout's bounds, grown right and down to hold every label.
    public var bounds: CGRect
}

/// Places each label on its wire, clear of seat cards and of each other.
///
/// A label that is clear at the middle of its wire's longest clear run stays there. Otherwise it moves to the best spot
/// that touches its wire: centred on it if that fits, else beside it with one edge on the wire. Among those it prefers
/// open canvas over a pod's frame, and a pod's frame over its title.
public func placeLabels(_ labels: [WireLabel], on wires: [Wire], in layout: CanvasLayout) -> LabelPlacement {
    let wireByID = Dictionary(wires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let ordered = labels.filter { wireByID[$0.wireID] != nil }.sorted { $0.wireID < $1.wireID }
    let scene = LabelScene(layout: layout)
    var placed: [String: CGRect] = [:]

    // Rule 4: labels clear at today's spot keep it. Placed first so a moved label can't take a clear one's place.
    var moving: [WireLabel] = []
    for label in ordered {
        let wire = wireByID[label.wireID]!
        let box = centred(at: todaysSpot(wire, avoiding: scene.seats), size: label.size)
        if scene.seatOverlap(box) == 0, scene.labelOverlap(box, placed.values) == 0, box.minX >= 0, box.minY >= 0 {
            placed[label.wireID] = box
        } else {
            moving.append(label)
        }
    }
    for label in moving {
        let wire = wireByID[label.wireID]!
        let today = todaysSpot(wire, avoiding: scene.seats)
        var best: (score: Score, box: CGRect)?
        for spot in candidates(on: wire, size: label.size) where spot.box.minX >= 0 && spot.box.minY >= 0 {
            let score = scene.score(spot, others: placed.values, today: today)
            if best == nil || score < best!.score { best = (score, spot.box) }
        }
        placed[label.wireID] = best?.box ?? centred(at: today, size: label.size)
    }

    var bounds = layout.bounds
    for box in placed.values {
        bounds.size.width = max(bounds.width, box.maxX + layout.metrics.podPadding - bounds.minX)
        bounds.size.height = max(bounds.height, box.maxY + layout.metrics.podPadding - bounds.minY)
    }
    return LabelPlacement(frames: placed, bounds: bounds)
}

/// The midpoint of the wire's longest segment whose midpoint is 10 pt clear of every seat.
func todaysSpot(_ wire: Wire, avoiding rects: [CGRect], clearance: CGFloat = 10) -> CGPoint {
    let segments = wire.segments.sorted { length($0) > length($1) }
    for (a, b) in segments {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if !rects.contains(where: { $0.insetBy(dx: -clearance, dy: -clearance).contains(mid) }) { return mid }
    }
    guard let (a, b) = segments.first else { return wire.points.first ?? .zero }
    return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

private func length(_ s: (CGPoint, CGPoint)) -> CGFloat {
    abs(s.0.x - s.1.x) + abs(s.0.y - s.1.y)
}

private func centred(at p: CGPoint, size: CGSize) -> CGRect {
    CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
}

/// Where a candidate box sits relative to its wire. Lower is preferred.
private enum Side: Int, Comparable {
    case centred, after, before  // after: right of or below the wire, as in the picked design
    static func < (l: Side, r: Side) -> Bool { l.rawValue < r.rawValue }
}

private struct Spot {
    var box: CGRect
    var side: Side
}

/// Boxes touching the wire every 4 pt along each segment: centred on it, and beside it on both sides.
private func candidates(on wire: Wire, size: CGSize) -> [Spot] {
    let (w, h) = (size.width, size.height)
    var out: [Spot] = []
    for (a, b) in wire.segments {
        let horizontal = a.y == b.y
        let (lo, hi) = horizontal ? (min(a.x, b.x), max(a.x, b.x)) : (min(a.y, b.y), max(a.y, b.y))
        var along = Array(stride(from: lo, through: hi, by: 4))
        along.append((lo + hi) / 2)
        for t in along {
            if horizontal {
                let x = t - w / 2
                out.append(Spot(box: CGRect(x: x, y: a.y - h / 2, width: w, height: h), side: .centred))
                out.append(Spot(box: CGRect(x: x, y: a.y, width: w, height: h), side: .after))
                out.append(Spot(box: CGRect(x: x, y: a.y - h, width: w, height: h), side: .before))
            } else {
                let y = t - h / 2
                out.append(Spot(box: CGRect(x: a.x - w / 2, y: y, width: w, height: h), side: .centred))
                out.append(Spot(box: CGRect(x: a.x, y: y, width: w, height: h), side: .after))
                out.append(Spot(box: CGRect(x: a.x - w, y: y, width: w, height: h), side: .before))
            }
        }
    }
    return out
}

/// Compared in order: each field outranks every field after it.
private struct Score: Comparable {
    var onSeats: CGFloat  // rule 1
    var onLabels: CGFloat  // rule 2
    var beside: Int  // rule 3: 0 centred on the wire, 1 beside it
    var growsBounds: Int
    var inPod: Int  // rule 5: 0 open canvas, 1 a pod's frame, 2 a pod's title
    var side: Side
    var distance: CGFloat  // from today's spot
    var x: CGFloat
    var y: CGFloat

    static func < (l: Score, r: Score) -> Bool {
        (l.onSeats, l.onLabels, l.beside, l.growsBounds) < (r.onSeats, r.onLabels, r.beside, r.growsBounds)
            || (l.onSeats, l.onLabels, l.beside, l.growsBounds) == (r.onSeats, r.onLabels, r.beside, r.growsBounds)
                && (l.inPod, l.side, l.distance, l.x, l.y) < (r.inPod, r.side, r.distance, r.x, r.y)
    }
}

private struct LabelScene {
    /// Rule 1's margin: the selection ring is 3 pt outside the label.
    static let ring: CGFloat = 4
    let seats: [CGRect]
    let pods: [CGRect]
    let titles: [CGRect]
    let bounds: CGRect

    init(layout: CanvasLayout) {
        seats = layout.seats.keys.sorted().map { layout.seats[$0]! }
        pods = layout.pods.keys.sorted().map { layout.pods[$0]! }
        titles = pods.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: layout.metrics.podHeader) }
        bounds = layout.bounds
    }

    func seatOverlap(_ box: CGRect) -> CGFloat {
        overlap(box.insetBy(dx: -Self.ring, dy: -Self.ring), seats)
    }

    /// Room for a selection ring between two labels.
    func labelOverlap(_ box: CGRect, _ others: some Sequence<CGRect>) -> CGFloat {
        overlap(box.insetBy(dx: -Self.ring, dy: -Self.ring), others)
    }

    func score(_ spot: Spot, others: some Sequence<CGRect>, today: CGPoint) -> Score {
        let box = spot.box
        let inPod = titles.contains { $0.intersects(box) } ? 2 : pods.contains { $0.intersects(box) } ? 1 : 0
        return Score(
            onSeats: seatOverlap(box), onLabels: labelOverlap(box, others), beside: spot.side == .centred ? 0 : 1,
            growsBounds: box.maxX > bounds.maxX || box.maxY > bounds.maxY ? 1 : 0, inPod: inPod, side: spot.side,
            distance: hypot(box.midX - today.x, box.midY - today.y), x: box.minX, y: box.minY)
    }
}

private func overlap(_ box: CGRect, _ rects: some Sequence<CGRect>) -> CGFloat {
    rects.reduce(0) { sum, r in
        let i = box.intersection(r)
        return i.isNull ? sum : sum + i.width * i.height
    }
}

import CoreGraphics
import RigCanvasLayout
import RigModel

/// Wires for work in flight: one per active qitem between two seats of this rig, plus past hops along
/// the selected item's chain and its planned next hop. Ids are `q:<qitem>`, `past:<qitem>` and `next:<qitem>`.
public func workWireRequests(_ items: [QItem], graph: RigGraph, chain: Chain?, next: NextHop? = nil)
    -> [WireRequest]
{
    var seatBySession: [String: Seat.ID] = [:]
    for seat in graph.seats {
        if let name = seat.sessionName { seatBySession[name] = seat.id }
    }

    var requests: [WireRequest] = []
    for item in items {
        let status = workStatus(item)
        guard status.isActive, let source = seatBySession[item.source],
            let target = seatBySession[item.destination], source != target
        else { continue }
        requests.append(
            WireRequest(
                id: "q:\(item.id)", source: source, target: target, kind: status.needsYou ? .needsYou : .inFlight))
    }

    if let chain {
        let loaded = chain.links.compactMap { link -> QItem? in
            if case .loaded(let item) = link { item } else { nil }
        }
        for (from, to) in zip(loaded, loaded.dropFirst()) {
            guard let source = seatBySession[from.destination], let target = seatBySession[to.destination],
                source != target
            else { continue }
            requests.append(WireRequest(id: "past:\(to.id)", source: source, target: target, kind: .past))
        }
    }

    if let next, let current = items.first(where: { $0.id == next.qitemID }),
        let source = seatBySession[current.destination], let target = seatBySession[next.owner], source != target
    {
        requests.append(WireRequest(id: "next:\(next.qitemID)", source: source, target: target, kind: .next))
    }
    return requests
}

/// Routes spec and work wires together. A work wire between a pair that already has a spec edge
/// takes that edge's geometry, so it draws on top of it instead of in a lane beside it.
public func routeCanvas(_ layout: CanvasLayout, spec: [WireRequest], work: [WireRequest]) -> RouteResult {
    var specByPair: [String: String] = [:]
    for request in spec { specByPair["\(request.source)>\(request.target)"] = request.id }
    let fresh = work.filter { specByPair["\($0.source)>\($0.target)"] == nil }
    // Several work items on one new pair share one routed wire.
    var seenPairs = Set<String>()
    let freshUnique = fresh.filter { seenPairs.insert("\($0.source)>\($0.target)").inserted }
    let routed = route(layout, spec + freshUnique)
    let byID = Dictionary(uniqueKeysWithValues: routed.wires.map { ($0.id, $0) })
    var byPair: [String: Wire] = [:]
    for wire in routed.wires where byPair["\(wire.source)>\(wire.target)"] == nil {
        byPair["\(wire.source)>\(wire.target)"] = wire
    }

    var wires = spec.compactMap { byID[$0.id] }
    for request in work {
        guard var wire = byPair["\(request.source)>\(request.target)"] else { continue }
        wire.id = request.id
        wire.kind = request.kind
        wires.append(wire)
    }
    return RouteResult(wires: wires, junctions: routed.junctions)
}

/// Where a wire's label chip goes: the midpoint of its longest segment that stays clear of every rect.
public func chipAnchor(for wire: Wire, avoiding rects: [CGRect], clearance: CGFloat = 10) -> CGPoint {
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

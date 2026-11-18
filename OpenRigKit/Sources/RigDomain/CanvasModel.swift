import CoreGraphics
import RigCanvasLayout
import RigModel

/// Seats whose pod is missing from the graph are grouped under this pod id.
public let unassignedPodID = "unassigned"

/// The rig as the layout engine sees it: pods in daemon order, flows pointing the way work moves.
public func layoutInput(for graph: RigGraph, seatSizes: [String: CGSize] = [:]) -> LayoutInput {
    let podIDs = Set(graph.pods.map(\.id))
    var pods = graph.pods.map { pod in
        LayoutInput.Pod(id: pod.id, seatIDs: graph.seats(in: pod.id).map(\.id))
    }
    let orphans = graph.seats.filter { $0.podID.map { !podIDs.contains($0) } ?? true }.map(\.id)
    if !orphans.isEmpty { pods.append(.init(id: unassignedPodID, seatIDs: orphans)) }

    let flows = specWireRequests(for: graph).map { LayoutInput.Flow(source: $0.source, target: $0.target) }
    return LayoutInput(pods: pods, flows: flows, seatSizes: seatSizes)
}

/// One wire per spec edge. `can_observe` points from observer to observed seat in the spec;
/// the wire runs the other way, from the seat being watched to its observer.
public func specWireRequests(for graph: RigGraph) -> [WireRequest] {
    let seatIDs = Set(graph.seats.map(\.id))
    return graph.edges.compactMap { edge in
        guard edge.source != edge.target, seatIDs.contains(edge.source), seatIDs.contains(edge.target) else {
            return nil
        }
        switch edge.kind {
        case .delegatesTo:
            return WireRequest(id: edge.id, source: edge.source, target: edge.target, kind: .delegates)
        case .canObserve:
            return WireRequest(id: edge.id, source: edge.target, target: edge.source, kind: .observes)
        default:
            return WireRequest(id: edge.id, source: edge.source, target: edge.target, kind: .related)
        }
    }
}

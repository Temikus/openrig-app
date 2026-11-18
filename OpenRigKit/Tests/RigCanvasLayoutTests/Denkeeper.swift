import CoreGraphics

@testable import RigCanvasLayout

/// The denkeeper rig's topology, as recorded in RigModelTests/Fixtures/graph-denkeeper.json.
/// Flows point the way work or attention moves: delegates_to as given, can_observe reversed.
enum Denkeeper {
    static let pods: [LayoutInput.Pod] = [
        .init(id: "orch", seatIDs: ["lead", "plan"]),
        .init(id: "dev", seatIDs: ["b1", "b2"]),
        .init(id: "review", seatIDs: ["design", "frontend", "security"]),
    ]

    static let delegates: [(String, String)] = [
        ("lead", "plan"), ("lead", "b1"), ("lead", "b2"),
        ("lead", "security"), ("lead", "design"), ("lead", "frontend"),
    ]
    // review.x can_observe dev.y, drawn from the observed seat to the observer.
    static let observes: [(String, String)] = [
        ("b1", "security"), ("b2", "security"), ("b1", "frontend"), ("b2", "frontend"),
    ]

    static var input: LayoutInput {
        LayoutInput(pods: pods, flows: (delegates + observes).map { LayoutInput.Flow(source: $0.0, target: $0.1) })
    }

    static var requests: [WireRequest] {
        delegates.map { WireRequest(id: "d:\($0.0)>\($0.1)", source: $0.0, target: $0.1, kind: .delegates) }
            + observes.map { WireRequest(id: "o:\($0.0)>\($0.1)", source: $0.0, target: $0.1, kind: .observes) }
    }
}

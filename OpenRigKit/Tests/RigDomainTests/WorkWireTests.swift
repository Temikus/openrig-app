import CoreGraphics
import RigCanvasLayout
import RigModel
import Testing

@testable import RigDomain

@Suite struct WorkWireTests {
    let graph = RigGraph(
        pods: [Pod(id: "p1", logicalId: "p1", label: "P1"), Pod(id: "p2", logicalId: "p2", label: "P2")],
        seats: [
            Seat(id: "lead", podID: "p1", logicalId: "lead", sessionName: "lead@r"),
            Seat(id: "b1", podID: "p2", logicalId: "b1", sessionName: "b1@r"),
            Seat(id: "b2", podID: "p2", logicalId: "b2", sessionName: "b2@r"),
        ],
        edges: [SpecEdge(id: "e1", source: "lead", target: "b1", kind: .delegatesTo)]
    )

    @Test func activeItemsBecomeWires() {
        let rows = [
            item("q1", .inProgress, from: "lead@r", to: "b1@r"),
            item("q2", .blocked, from: "lead@r", to: "b2@r", blockedOn: "external:human"),
            item("q3", .done, from: "lead@r", to: "b2@r", closureReason: "no-follow-on"),
            item("q4", .pending, from: "b1@r", to: "b1@r"),
            item("q5", .pending, from: "elsewhere@x", to: "b1@r"),
        ]
        let requests = workWireRequests(rows, graph: graph, chain: nil)
        #expect(requests.map(\.id) == ["q:q1", "q:q2"])
        #expect(requests.map(\.kind) == [.inFlight, .needsYou])
        #expect(requests[1].source == "lead" && requests[1].target == "b2")
    }

    @Test func selectedChainAddsPastHops() {
        let rows = [
            item("a", .done, from: "lead@r", to: "b1@r", closureReason: "handed_off_to", closureTarget: "b2@r"),
            item("b", .inProgress, from: "b1@r", to: "b2@r", after: "a"),
        ]
        let chain = ChainIndex(rows).chain(for: "b")
        let past = workWireRequests(rows, graph: graph, chain: chain).filter { $0.kind == .past }
        #expect(past.map { "\($0.source)>\($0.target)" } == ["b1>b2"])
    }

    @Test func workOnASpecPairReusesItsGeometry() throws {
        let layout = layoutRig(layoutInput(for: graph))
        let spec = specWireRequests(for: graph)
        let work = workWireRequests([item("q1", from: "lead@r", to: "b1@r")], graph: graph, chain: nil)
        let result = routeCanvas(layout, spec: spec, work: work)
        let specWire = try #require(result.wires.first { $0.id == "e1" })
        let workWire = try #require(result.wires.first { $0.id == "q:q1" })
        #expect(workWire.points == specWire.points)
        #expect(workWire.kind == .inFlight)
    }

    @Test func chipSitsOnTheLongestClearSegment() throws {
        let layout = layoutRig(layoutInput(for: graph))
        let work = workWireRequests([item("q2", from: "lead@r", to: "b2@r")], graph: graph, chain: nil)
        let wire = try #require(routeCanvas(layout, spec: [], work: work).wires.first)
        let chip = chipAnchor(for: wire, avoiding: Array(layout.seats.values))
        #expect(
            wire.segments.contains { a, b in
                (a.x == b.x && chip.x == a.x) || (a.y == b.y && chip.y == a.y)
            })
        #expect(!layout.seats.values.contains { $0.insetBy(dx: -4, dy: -4).contains(chip) })
    }
}

@Suite struct NextHopWireTests {
    let graph = RigGraph(seats: [
        Seat(id: "lead", logicalId: "lead", sessionName: "lead@r"),
        Seat(id: "b1", logicalId: "b1", sessionName: "b1@r"),
    ])

    @Test func nextHopDrawsFromTheCurrentOwner() {
        let rows = [item("q1", .inProgress, from: "elsewhere@x", to: "lead@r")]
        let hop = NextHop(qitemID: "q1", stepID: "plan", nextStepID: "build", owner: "b1@r")
        let next = workWireRequests(rows, graph: graph, chain: nil, next: hop).filter { $0.kind == .next }
        #expect(next.map(\.id) == ["next:q1"])
        #expect(next.map { "\($0.source)>\($0.target)" } == ["lead>b1"])

        let same = NextHop(qitemID: "q1", stepID: "plan", nextStepID: "check", owner: "lead@r")
        #expect(workWireRequests(rows, graph: graph, chain: nil, next: same).allSatisfy { $0.kind != .next })
    }
}

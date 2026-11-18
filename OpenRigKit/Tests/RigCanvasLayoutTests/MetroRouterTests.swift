import CoreGraphics
import Testing

@testable import RigCanvasLayout

@Suite struct MetroRouterTests {
    let layout = layoutRig(Denkeeper.input)
    let result: RouteResult

    init() {
        result = route(layoutRig(Denkeeper.input), Denkeeper.requests)
    }

    func wire(_ id: String) throws -> Wire {
        try #require(result.wires.first { $0.id == id })
    }

    @Test func everyRequestIsRouted() {
        #expect(result.wires.map(\.id) == Denkeeper.requests.map(\.id))
    }

    @Test func wiresRunFromOutPortToInPort() {
        for w in result.wires {
            #expect(w.points.first == layout.outPort(w.source), "\(w.id)")
            #expect(w.points.last == layout.inPort(w.target), "\(w.id)")
        }
    }

    @Test func everySegmentIsAxisAligned() {
        for w in result.wires {
            for (a, b) in w.segments {
                #expect(a.x == b.x || a.y == b.y, "\(w.id): \(a) → \(b)")
                #expect(a != b, "\(w.id) has a zero-length segment")
            }
        }
    }

    @Test func noSegmentEntersAnotherNode() {
        for w in result.wires {
            for (seat, rect) in layout.seats where seat != w.source && seat != w.target {
                for (a, b) in w.segments {
                    #expect(!segment(a, b, entersInteriorOf: rect), "\(w.id) crosses \(seat)")
                }
            }
            // Its own endpoints may only be touched at the ports.
            for seat in [w.source, w.target] {
                for (a, b) in w.segments.dropFirst().dropLast() {
                    #expect(!segment(a, b, entersInteriorOf: layout.seats[seat]!), "\(w.id) re-enters \(seat)")
                }
            }
        }
    }

    @Test func sameSourceWiresShareATrunk() throws {
        // lead fans out from one shared first run; a wire that runs straight across has no bend to share.
        let fromLead = result.wires.filter { $0.source == "lead" && $0.bends > 0 }
        #expect(fromLead.count >= 4)
        let firstLegs = Set(fromLead.map { $0.points[1] })
        #expect(firstLegs.count == 1, "first bend should coincide: \(firstLegs)")
        #expect(result.junctions.contains(firstLegs.first!), "trunk branch gets a junction dot")
    }

    @Test func differentSourceParallelSegmentsAreALaneApart() {
        let interior = result.wires.flatMap { w in w.segments.dropFirst().dropLast().map { (w.source, $0.0, $0.1) } }
        for (i, s) in interior.enumerated() {
            for t in interior[(i + 1)...] where s.0 != t.0 {
                if s.1.x == s.2.x && t.1.x == t.2.x, overlap(s.1.y, s.2.y, t.1.y, t.2.y) {
                    #expect(abs(s.1.x - t.1.x) >= 8, "\(s.0)/\(t.0) at x=\(s.1.x)")
                }
                if s.1.y == s.2.y && t.1.y == t.2.y, overlap(s.1.x, s.2.x, t.1.x, t.2.x) {
                    #expect(abs(s.1.y - t.1.y) >= 8, "\(s.0)/\(t.0) at y=\(s.1.y)")
                }
            }
        }
    }

    @Test func deterministic() {
        #expect(route(layout, Denkeeper.requests) == result)
        #expect(
            route(layout, Denkeeper.requests.reversed()).wires.sorted { $0.id < $1.id }
                == result.wires.sorted { $0.id < $1.id })
    }

    // Golden topology, from the design prototype's polylines (scratch metro.py).
    @Test func goldenBends() throws {
        #expect(try wire("d:lead>b1").bends == 0, "lead and dev-b1 ports line up")
        #expect(try wire("d:lead>b2").bends == 2)
        #expect(try wire("o:b2>security").bends == 2)
        #expect(try wire("d:lead>design").bends <= 4)
        #expect(try wire("d:lead>plan").bends <= 4)
    }

    @Test func trunkAvoidsRunningThroughOtherPods() throws {
        let dev = layout.pods["dev"]!
        for (a, b) in try wire("d:lead>design").segments where a.y == b.y {
            #expect(!(a.y > dev.minY && a.y < dev.maxY && overlap(a.x, b.x, dev.minX, dev.maxX)), "\(a) → \(b)")
        }
    }

    @Test func leadToPlanUsesTheChannelBetweenColumns() throws {
        // It leaves lead to the right, so it must turn in the channel between orch and dev.
        let points = try wire("d:lead>plan").points
        let orch = layout.pods["orch"]!, dev = layout.pods["dev"]!
        #expect(points.contains { $0.x > orch.maxX && $0.x < dev.minX })
    }

    @Test func roundedCornerRadiusShrinksOnShortSegments() {
        #expect(cornerRadius(previous: 100, next: 100) == 10)
        #expect(cornerRadius(previous: 6, next: 100) == 3)
    }

    @Test func emptyRequestsGiveNothing() {
        #expect(route(layout, []) == RouteResult(wires: [], junctions: []))
    }

    @Test func unknownSeatIsSkipped() {
        let r = route(layout, [WireRequest(id: "x", source: "lead", target: "ghost", kind: .delegates)])
        #expect(r.wires.isEmpty)
    }
}

func overlap(_ a1: CGFloat, _ a2: CGFloat, _ b1: CGFloat, _ b2: CGFloat) -> Bool {
    max(min(a1, a2), min(b1, b2)) < min(max(a1, a2), max(b1, b2))
}

func segment(_ a: CGPoint, _ b: CGPoint, entersInteriorOf rect: CGRect) -> Bool {
    let inner = rect.insetBy(dx: 0.5, dy: 0.5)
    if a.y == b.y {
        return a.y > inner.minY && a.y < inner.maxY && overlap(a.x, b.x, inner.minX, inner.maxX)
    }
    return a.x > inner.minX && a.x < inner.maxX && overlap(a.y, b.y, inner.minY, inner.maxY)
}

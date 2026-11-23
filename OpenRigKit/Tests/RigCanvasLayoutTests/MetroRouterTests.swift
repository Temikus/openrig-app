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
            // A second bundle into the same seat enters a lane below the port (staggerInPorts).
            let port = layout.inPort(w.target), end = w.points.last!
            #expect(end.x == port.x && [0, 8, 16].contains(end.y - port.y), "\(w.id) ends at \(end), port \(port)")
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

    @Test func thinnedKeepsOneDotPerClump() {
        let clump = [CGPoint(x: 100, y: 50), CGPoint(x: 108, y: 50), CGPoint(x: 100, y: 58), CGPoint(x: 120, y: 50)]
        #expect(thinned(clump, within: 8) == [CGPoint(x: 100, y: 50), CGPoint(x: 120, y: 50)])
    }

    @Test func noTwoJunctionsWithinALane() {
        for (i, a) in result.junctions.enumerated() {
            for b in result.junctions[(i + 1)...] {
                #expect(abs(a.x - b.x) > 8 || abs(a.y - b.y) > 8, "\(a) and \(b) clump")
            }
        }
    }

    @Test func sameKindFanInIsOneBundle() {
        let ids = bundles(Denkeeper.requests)
        #expect(Set(Denkeeper.observes.map { ids["o:\($0.0)>\($0.1)"] }).count == 1, "both builders' watch lines")
        #expect(Set(Denkeeper.delegates.map { ids["d:\($0.0)>\($0.1)"] }).count == 1)
        #expect(ids["o:b1>frontend"] != ids["d:lead>frontend"], "kinds never bundle")
    }

    @Test func bundlesOnlyWhenEverySourceReachesEveryTarget() {
        // a→p, b→p, b→q: one trunk would suggest a→q, so each source keeps its own fan-out.
        let chain = [("a", "p"), ("b", "p"), ("b", "q")].map {
            WireRequest(id: "\($0.0)>\($0.1)", source: $0.0, target: $0.1, kind: .observes)
        }
        let ids = bundles(chain)
        #expect(ids["a>p"] != ids["b>p"])
        #expect(ids["b>p"] == ids["b>q"])
    }

    @Test func bundlesIntoOneSeatEnterOnTheirOwnRuns() {
        for (target, wires) in Dictionary(grouping: result.wires, by: \.target) {
            let byBundle = Dictionary(grouping: wires, by: \.bundle).mapValues { Set($0.map { $0.points.last!.y }) }
            let ys = byBundle.values.flatMap(\.self)
            #expect(Set(ys).count == ys.count, "\(target): bundles share a final run \(byBundle)")
        }
    }

    @Test func staggerNeverReversesAShortClimbIntoThePort() {
        // Two bundles into "t". The watch wire climbs 4 pt into the port: an 8 pt shift would turn it back on itself.
        let port = CGPoint(x: 100, y: 50)
        var wires = [
            Wire(
                id: "d", source: "a", target: "t", kind: .delegates, bundle: "d",
                points: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 50), port]),
            Wire(
                id: "o", source: "b", target: "t", kind: .observes, bundle: "o",
                points: [CGPoint(x: 0, y: 54), CGPoint(x: 70, y: 54), CGPoint(x: 70, y: 50), port]),
            Wire(
                id: "o2", source: "c", target: "t", kind: .observes, bundle: "o",
                points: [CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 0), CGPoint(x: 70, y: 50), port]),
        ]
        let short = wires[1].points
        staggerInPorts(&wires, spacing: 8)
        #expect(wires[0].points.last == port, "the spec wire keeps the port")
        #expect(wires[1].points == short, "a 4 pt climb isn't stretched past itself")
        #expect(wires[2].points.last == CGPoint(x: 100, y: 58), "a descent lengthens and enters below")
    }

    @Test func watchLinesShareOneLaneOnTheBuildersSide() throws {
        // In the channel between builders and reviewers, every vertical run of each kind.
        let dev = layout.pods["dev"]!, review = layout.pods["review"]!
        func channelXs(_ kind: WireKind) -> Set<CGFloat> {
            Set(
                result.wires.filter { $0.kind == kind }.flatMap(\.segments)
                    .filter { $0.0.x == $0.1.x && $0.0.x > dev.maxX && $0.0.x < review.minX }.map(\.0.x))
        }
        let watch = channelXs(.observes), spec = channelXs(.delegates)
        #expect(watch.count == 1, "one watch trunk, not one per builder: \(watch)")
        #expect(watch.max()! < spec.min()!, "watch lane builder-side of the spec lane: \(watch) vs \(spec)")
    }

    @Test func differentBundleParallelSegmentsAreALaneApart() {
        let interior = result.wires.flatMap { w in w.segments.dropFirst().dropLast().map { (w.bundle, $0.0, $0.1) } }
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

    @Test func workWireGoesAroundRatherThanCrossASpecWire() throws {
        // plan→lead and the spec wire lead→plan both cross the seat column. Through the gap between the seats their
        // ends interleave, so lanes can't keep them apart; one has to go around plan instead.
        var input = Denkeeper.input
        input.seatSizes["plan"] = CGSize(width: 216, height: 140)
        let layout = layoutRig(input)
        let work = WireRequest(id: "q:back", source: "plan", target: "lead", kind: .inFlight)
        let wires = route(layout, Denkeeper.requests + [work]).wires
        let spec = try #require(wires.first { $0.id == "d:lead>plan" })
        let back = try #require(wires.first { $0.id == "q:back" })
        #expect(crossings(spec, back) == 0, "\(spec.points) vs \(back.points)")
        let alone = try #require(route(layout, Denkeeper.requests).wires.first { $0.id == "d:lead>plan" })
        #expect(spec.bends == alone.bends, "the work wire detours, not the spec wire")
        #expect(back.points.contains { $0.y > layout.seats["plan"]!.maxY }, "around plan, under it")
    }

    @Test func watchLinesDontPullSpecWiresIntoDetours() throws {
        // The watch lines into frontend cross the delegates trunk. They draw faint, so the trunk stays the short way.
        #expect(try wire("d:lead>frontend").bends == 4)
    }

    @Test func noDetourPastTheBudget() {
        var input = Denkeeper.input
        input.seatSizes["plan"] = CGSize(width: 216, height: 140)
        let layout = layoutRig(input)
        let work = WireRequest(id: "q:back", source: "plan", target: "lead", kind: .inFlight)
        var tight = RouterOptions()
        tight.detourPerCrossing = 0
        let wires = route(layout, Denkeeper.requests + [work], options: tight).wires
        let spec = wires.first { $0.id == "d:lead>plan" }!, back = wires.first { $0.id == "q:back" }!
        #expect(crossings(spec, back) == 1, "no detour is free")
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

/// Points where a segment of one wire passes through the interior of a perpendicular segment of the other.
func crossings(_ a: Wire, _ b: Wire) -> Int {
    var n = 0
    for (p, q) in a.segments {
        for (r, s) in b.segments {
            let (h, v) = p.y == q.y ? ((p, q), (r, s)) : ((r, s), (p, q))
            guard h.0.y == h.1.y, v.0.x == v.1.x, h.0 != h.1, v.0 != v.1 else { continue }
            let x = v.0.x, y = h.0.y
            if min(h.0.x, h.1.x) < x, x < max(h.0.x, h.1.x), min(v.0.y, v.1.y) < y, y < max(v.0.y, v.1.y) { n += 1 }
        }
    }
    return n
}

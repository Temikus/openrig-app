import CoreGraphics
import Testing

@testable import RigCanvasLayout

@Suite struct WireLabelTests {
    /// Rule 1's margin: the selection ring is 3 pt outside the label.
    static let ring: CGFloat = 4
    static let short = CGSize(width: 50, height: 16)
    static let blocked = CGSize(width: 110, height: 16)

    /// The reported case: with spec wires in the column channel and the lead's card grown, a builder-to-builder wire
    /// runs down the dev pod's inner edge, 16 pt from the card. Centred there, its label slid under the card.
    @Test func labelOnAWireDownAPodsInnerEdgeStaysOffTheCard() throws {
        var input = Denkeeper.input
        input.seatSizes["lead"] = CGSize(width: 216, height: 140)
        let layout = layoutRig(input)
        let work = [
            WireRequest(id: "q:same", source: "b1", target: "b2", kind: .inFlight),
            WireRequest(id: "q:across", source: "b1", target: "lead", kind: .inFlight),
        ]
        let wires = route(layout, Denkeeper.requests + work).wires
        let same = try #require(wires.first { $0.id == "q:same" })
        let card = try #require(layout.seats["b1"])
        #expect(
            same.segments.contains { a, b in a.x == b.x && a.x == card.maxX + 16 }, "the case moved: \(same.points)")

        let labels = work.map { WireLabel(wireID: $0.id, size: Self.short) }
        let placed = placeLabels(labels, on: wires, in: layout)
        for label in labels {
            let wire = try #require(wires.first { $0.id == label.wireID })
            let frame = try #require(placed.frames[label.wireID])
            #expect(clearOfSeats(frame, layout), "\(label.wireID) at \(frame)")
            #expect(touches(frame, wire), "\(label.wireID) at \(frame)")
        }
    }

    /// Denkeeper's spec wires plus a work wire for every ordered pair of seats, at default seat heights and with each
    /// seat in turn as tall as a prompt card. Labels of 50 and 110 pt, and a 140 pt "next:" label, which is capped.
    @Test(arguments: [nil] + Denkeeper.pods.flatMap(\.seatIDs))
    func everyLabelClearsTheCardsAndTouchesItsWire(tall: String?) throws {
        var input = Denkeeper.input
        if let tall { input.seatSizes[tall] = CGSize(width: 216, height: 220) }
        let layout = layoutRig(input)
        let seats = Denkeeper.pods.flatMap(\.seatIDs)
        for source in seats {
            for target in seats where target != source {
                let work = WireRequest(id: "q:\(source)>\(target)", source: source, target: target, kind: .inFlight)
                let wires = route(layout, Denkeeper.requests + [work]).wires
                let wire = try #require(wires.first { $0.id == work.id })
                for size in [Self.short, Self.blocked, CGSize(width: 140, height: 16)] {
                    let placed = placeLabels([WireLabel(wireID: work.id, size: size)], on: wires, in: layout)
                    let frame = try #require(placed.frames[work.id])
                    #expect(frame.width == min(size.width, WireLabel.maxWidth))
                    #expect(clearOfSeats(frame, layout), "\(work.id) \(size.width) pt at \(frame)")
                    #expect(touches(frame, wire), "\(work.id) \(size.width) pt at \(frame)")
                    #expect(placed.bounds.contains(frame), "\(work.id) \(size.width) pt at \(frame)")
                    #expect(placed.bounds.origin == layout.bounds.origin)
                }
            }
        }
    }

    /// Two queue items between the same two seats share one wire.
    @Test func labelsSharingAWireDoNotOverlap() {
        let layout = layoutRig(Denkeeper.input)
        var wires = route(layout, [WireRequest(id: "q:1", source: "lead", target: "b2", kind: .inFlight)]).wires
        var twin = wires[0]
        twin.id = "q:2"
        wires.append(twin)
        let placed = placeLabels(
            [WireLabel(wireID: "q:1", size: Self.blocked), WireLabel(wireID: "q:2", size: Self.blocked)], on: wires,
            in: layout)
        expectApart(placed, layout: layout, wires: wires)
    }

    @Test func labelsOnAFanOutDoNotOverlap() {
        let layout = layoutRig(Denkeeper.input)
        let work = ["b1", "b2", "plan"].map {
            WireRequest(id: "q:\($0)", source: "lead", target: $0, kind: .inFlight)
        }
        let wires = route(layout, work).wires
        let placed = placeLabels(work.map { WireLabel(wireID: $0.id, size: Self.blocked) }, on: wires, in: layout)
        expectApart(placed, layout: layout, wires: wires)
    }

    /// Rule 4: a label already clear where it went before (the middle of the longest clear run) stays put.
    @Test func aClearLabelBetweenPodsStaysWhereItWas() throws {
        let layout = layoutRig(Denkeeper.input)
        let wires = route(layout, [WireRequest(id: "q:1", source: "b2", target: "security", kind: .inFlight)]).wires
        let today = todaysSpot(wires[0], avoiding: Array(layout.seats.values))
        let frame = try #require(
            placeLabels([WireLabel(wireID: "q:1", size: Self.short)], on: wires, in: layout).frames["q:1"])
        #expect(CGPoint(x: frame.midX, y: frame.midY) == today)
    }

    /// Rule 6, whatever order the labels come in.
    @Test func sameInputSamePlacement() {
        let layout = layoutRig(Denkeeper.input)
        let seats = Denkeeper.pods.flatMap(\.seatIDs)
        let work = seats.flatMap { s in
            seats.filter { $0 != s }.map { WireRequest(id: "q:\(s)>\($0)", source: s, target: $0, kind: .inFlight) }
        }
        let wires = route(layout, Denkeeper.requests + work).wires
        let labels = work.map { WireLabel(wireID: $0.id, size: Self.short) }
        let first = placeLabels(labels, on: wires, in: layout)
        #expect(placeLabels(labels, on: wires, in: layout) == first)
        #expect(placeLabels(labels.reversed(), on: wires.reversed(), in: layout) == first)
    }

    /// The last column has no gap to hang into, so the bounds grow to hold the label.
    @Test func boundsGrowForALabelPastTheLastColumn() throws {
        let input = LayoutInput(pods: [.init(id: "solo", seatIDs: ["top", "bottom"])], flows: [])
        let layout = layoutRig(input)
        let wide = CGSize(width: WireLabel.maxWidth, height: 16)
        let others = [WireRequest(id: "o", source: "top", target: "bottom", kind: .observes)]
        let wires = route(layout, others + [WireRequest(id: "q:1", source: "top", target: "bottom", kind: .inFlight)])
            .wires
        let wire = try #require(wires.first { $0.id == "q:1" })
        let placed = placeLabels([WireLabel(wireID: "q:1", size: wide)], on: wires, in: layout)
        let frame = try #require(placed.frames["q:1"])
        #expect(clearOfSeats(frame, layout), "\(frame)")
        #expect(touches(frame, wire), "\(frame)")
        #expect(placed.bounds.contains(frame), "\(frame) in \(placed.bounds)")
        #expect(placed.bounds.width > layout.bounds.width)
    }
}

func clearOfSeats(_ frame: CGRect, _ layout: CanvasLayout) -> Bool {
    let grown = frame.insetBy(dx: -WireLabelTests.ring, dy: -WireLabelTests.ring)
    return !layout.seats.values.contains { $0.intersects(grown) }
}

/// Some segment of the wire meets the box or runs along one of its edges.
func touches(_ frame: CGRect, _ wire: Wire) -> Bool {
    wire.segments.contains { a, b in
        let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return frame.insetBy(dx: -0.5, dy: -0.5).intersects(seg.insetBy(dx: -0.01, dy: -0.01))
    }
}

func expectApart(_ placed: LabelPlacement, layout: CanvasLayout, wires: [Wire]) {
    let frames = placed.frames.sorted { $0.key < $1.key }
    for (i, a) in frames.enumerated() {
        #expect(clearOfSeats(a.value, layout), "\(a.key) at \(a.value)")
        if let wire = wires.first(where: { $0.id == a.key }) { #expect(touches(a.value, wire), "\(a.key)") }
        for b in frames.dropFirst(i + 1) {
            #expect(!a.value.intersects(b.value), "\(a.key) \(a.value) and \(b.key) \(b.value)")
        }
    }
}

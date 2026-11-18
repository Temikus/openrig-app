import CoreGraphics
import Testing

@testable import RigCanvasLayout

@Suite struct LayoutTests {
    let layout = layoutRig(Denkeeper.input)

    @Test func podsRankLeftToRightByFlow() throws {
        let orch = try #require(layout.pods["orch"])
        let dev = try #require(layout.pods["dev"])
        let review = try #require(layout.pods["review"])
        #expect(layout.podColumn == ["orch": 0, "dev": 1, "review": 2])
        #expect(orch.maxX < dev.minX)
        #expect(dev.maxX < review.minX)
    }

    @Test func seatsSitInsideTheirPodInSpecOrder() throws {
        for pod in Denkeeper.pods {
            let frame = try #require(layout.pods[pod.id])
            let seats = try pod.seatIDs.map { try #require(layout.seats[$0]) }
            #expect(seats.allSatisfy { frame.contains($0) })
            #expect(zip(seats, seats.dropFirst()).allSatisfy { $0.maxY < $1.minY })
        }
    }

    @Test func measuredHeightsAreUsed() {
        var input = Denkeeper.input
        input.seatSizes["lead"] = CGSize(width: 999, height: 180)
        let tall = layoutRig(input)
        #expect(tall.seats["lead"]?.height == 180)
        #expect(tall.seats["lead"]?.width == LayoutMetrics().seatWidth, "width is fixed by the column")
        #expect(tall.seats["plan"]!.minY > tall.seats["lead"]!.maxY)
    }

    @Test func boundsContainEverything() {
        let all = Array(layout.pods.values) + Array(layout.seats.values)
        #expect(all.allSatisfy { layout.bounds.contains($0) })
        #expect(layout.bounds.origin == .zero)
    }

    @Test func cyclesAreBrokenInSpecOrder() {
        // kernel: advisor delegates to operator and queue; queue escalates back to advisor.
        let input = LayoutInput(
            pods: [
                .init(id: "advisor", seatIDs: ["a"]), .init(id: "operator", seatIDs: ["o", "h"]),
                .init(id: "queue", seatIDs: ["q"]),
            ],
            flows: [.init(source: "a", target: "o"), .init(source: "a", target: "q"), .init(source: "q", target: "a")]
        )
        let result = layoutRig(input)
        #expect(result.podColumn == ["advisor": 0, "operator": 1, "queue": 1])
        #expect(result.pods["operator"]!.maxY < result.pods["queue"]!.minY, "same column stacks in spec order")
    }

    @Test func emptyPodStillGetsAFrame() {
        let result = layoutRig(LayoutInput(pods: [.init(id: "p", seatIDs: [])], flows: []))
        #expect(result.pods["p"]!.height > 0)
    }

    @Test func deterministic() {
        #expect(layoutRig(Denkeeper.input) == layout)
    }
}

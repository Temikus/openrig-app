import RigCanvasLayout
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

@Suite struct CanvasModelTests {
    @Test func denkeeperBecomesThreeColumns() throws {
        let graph: RigGraph = try RigFixtures.decode("graph-denkeeper")
        let input = layoutInput(for: graph)
        #expect(input.pods.map(\.seatIDs.count) == [2, 2, 3])
        let layout = layoutRig(input)
        let columns = Dictionary(uniqueKeysWithValues: graph.pods.map { ($0.label, layout.podColumn[$0.id]!) })
        #expect(columns == ["Orchestration": 0, "Builders": 1, "Reviewers": 2])
    }

    @Test func observeWiresRunFromTheWatchedSeat() throws {
        let graph: RigGraph = try RigFixtures.decode("graph-denkeeper")
        let requests = specWireRequests(for: graph)
        #expect(requests.count == 10)
        let name = Dictionary(uniqueKeysWithValues: graph.seats.map { ($0.id, $0.logicalId) })
        let observes = requests.filter { $0.kind == .observes }.map { "\(name[$0.source]!)>\(name[$0.target]!)" }
        #expect(
            Set(observes) == [
                "dev.b1>review.security", "dev.b2>review.security", "dev.b1>review.frontend", "dev.b2>review.frontend",
            ])
    }

    @Test func otherEdgeKindsAreRelated() throws {
        let graph: RigGraph = try RigFixtures.decode("graph-kernel")
        let kinds = specWireRequests(for: graph).map(\.kind)
        #expect(kinds.filter { $0 == .related }.count == 3)
        // The escalates_to cycle must still lay out.
        #expect(layoutRig(layoutInput(for: graph)).podColumn.count == 3)
    }

    @Test func seatsWithoutAPodGoToUnassigned() {
        let graph = RigGraph(
            pods: [Pod(id: "p", logicalId: "p", label: "P")],
            seats: [
                Seat(id: "a", podID: "p", logicalId: "a"), Seat(id: "b", podID: "gone", logicalId: "b"),
                Seat(id: "c", logicalId: "c"),
            ],
            edges: [SpecEdge(id: "e", source: "a", target: "zz", kind: .delegatesTo)])
        let input = layoutInput(for: graph)
        #expect(input.pods.map(\.id) == ["p", unassignedPodID])
        #expect(input.pods[1].seatIDs == ["b", "c"])
        #expect(specWireRequests(for: graph).isEmpty, "edges to unknown seats are dropped")
    }
}

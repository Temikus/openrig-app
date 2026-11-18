import Foundation
import Testing

@testable import RigModel

// Fixtures were recorded from a live rig 0.7.11 daemon (`just record-fixtures`),
// except graph-edge-cases.json, which is hand-written.
func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

@Suite struct HealthDecoding {
    @Test func recordedHealthz() throws {
        let health: DaemonHealth = try fixture("healthz")
        #expect(health.semver == "0.7.11")
        #expect(health.isHealthy)
    }

    @Test func unhealthyEventLoopIsNotHealthy() throws {
        let json = #"{"status":"ok","eventLoop":{"healthy":false}}"#
        let health = try JSONDecoder().decode(DaemonHealth.self, from: Data(json.utf8))
        #expect(!health.isHealthy)
    }
}

@Suite struct RigListDecoding {
    @Test func recordedPs() throws {
        let rigs: [RigSummary] = try fixture("ps")
        #expect(rigs.map(\.name) == ["denkeeper", "kernel"])
        let denkeeper = try #require(rigs.first)
        #expect(denkeeper.id == "01M7HZWZMPPHGNMT4TJPXP0H7J")
        #expect(denkeeper.status == .running)
        #expect(denkeeper.nodeCount == 7)
        #expect(denkeeper.runningCount == 7)
    }

    @Test func missingCountsDefaultToZero() throws {
        let json = #"[{"rigId":"r1","status":"partially-running"}]"#
        let rigs = try JSONDecoder().decode([RigSummary].self, from: Data(json.utf8))
        #expect(rigs[0].name == "r1")
        #expect(rigs[0].status.rawValue == "partially-running")
        #expect(rigs[0].nodeCount == 0)
    }
}

@Suite struct GraphDecoding {
    @Test func denkeeperTopology() throws {
        let graph: RigGraph = try fixture("graph-denkeeper")
        #expect(graph.pods.map(\.label).sorted() == ["Builders", "Orchestration", "Reviewers"])
        #expect(graph.seats.count == 7)
        #expect(graph.edges.count == 10)
        #expect(Set(graph.edges.map(\.kind)) == [.delegatesTo, .canObserve])

        let podIDs = Set(graph.pods.map(\.id))
        #expect(graph.seats.allSatisfy { $0.podID.map(podIDs.contains) == true })
        let seatIDs = Set(graph.seats.map(\.id))
        #expect(graph.edges.allSatisfy { seatIDs.contains($0.source) && seatIDs.contains($0.target) })
    }

    @Test func seatFieldsFromRecordedGraph() throws {
        let graph: RigGraph = try fixture("graph-denkeeper")
        let lead = try #require(graph.seats.first { $0.logicalId == "orch.lead" })
        #expect(lead.displayName == "orch-lead")
        #expect(lead.sessionName == "orch-lead@denkeeper")
        #expect(lead.tmuxPane == "%19")
        #expect(lead.runtime == "claude-code")
        #expect(lead.kind == .agent)
        #expect(lead.activity?.stale == true)
    }

    @Test func kernelKeepsUnknownEdgeLabelsAndInfrastructureSeats() throws {
        let graph: RigGraph = try fixture("graph-kernel")
        #expect(graph.edges.contains { $0.kind.rawValue == "collaborates_with" })
        #expect(graph.seats.contains { $0.kind == .infrastructure })
    }

    @Test func edgeCases() throws {
        let graph: RigGraph = try fixture("graph-edge-cases")
        #expect(graph.pods.count == 1)
        #expect(graph.seats.map(\.id) == ["seat-1", "seat-2"], "unknown node types and id-less nodes are dropped")
        #expect(graph.seats(in: "pod-a").count == 2)

        let b1 = graph.seats[0]
        #expect(b1.activity?.state == .needsInput)
        #expect(b1.needsAttention)
        #expect(b1.heldReason == "waiting on human")
        #expect(b1.contextUsedPercent == 42)
        #expect(b1.currentQItems.map(\.id) == ["qitem-20261111110308-f963e5f7"])
        #expect(b1.work == WorkCounts(pending: 2, inProgress: 1, blocked: 1))

        let b2 = graph.seats[1]
        #expect(b2.displayName == "dev-b2", "falls back to the logical id when there is no session name")
        #expect(b2.activity?.state.rawValue == "daydreaming")
        #expect(b2.contextUsedPercent == nil)
        #expect(b2.heldReason == nil)
        #expect(b2.status.rawValue == "unknown")

        #expect(graph.edges.map(\.kind.rawValue) == ["delegates_to", "mentors"], "edge without a target is dropped")
        #expect(graph.edges[1].id == "seat-2-mentors-seat-1")
    }
}

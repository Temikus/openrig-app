import Foundation
import RigFixtures
import Testing

@testable import RigModel

func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try RigFixtures.decode(name)
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
        #expect(denkeeper.lifecycle == .running)
        #expect(denkeeper.latestSnapshot == "1m ago")
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

@Suite struct FormattingTests {
    /// Workflow packets come with `summary: null`; the body's first line stands in.
    @Test func missingSummaryFallsBackToTheBody() throws {
        let json = #"""
            {"qitemId": "q1", "summary": null, "body": "\n### Workflow entry: hop@2 step draft\n\nMore."}
            """#
        let item = try JSONDecoder().decode(QItem.self, from: Data(json.utf8))
        #expect(item.summary == "Workflow entry: hop@2 step draft")
        let plain = try JSONDecoder().decode(QItem.self, from: Data(#"{"qitemId": "q2", "summary": "Real"}"#.utf8))
        #expect(plain.summary == "Real")
    }

    @Test func shortIDs() {
        #expect(shortQItemID("qitem-20261111110308-f963e5f7") == "q-e5f7")
        #expect(shortQItemID("abc") == "q-abc")
    }

    @Test(arguments: ["2026-11-18T03:18:49.547Z", "2026-11-18T03:18:49Z", "2026-11-18 03:18:49"])
    func daemonDates(raw: String) throws {
        let date = try #require(parseDaemonDate(raw))
        #expect(Int(date.timeIntervalSince1970) == 1_794_971_929)
    }

    @Test func activitySinceFromRecordedGraph() throws {
        let graph: RigGraph = try fixture("graph-denkeeper")
        let lead = try #require(graph.seats.first { $0.logicalId == "orch.lead" })
        #expect(lead.activity?.since == parseDaemonDate("2026-11-18T03:18:49.547Z"))
        let b1 = try #require(graph.seats.first { $0.logicalId == "dev.b1" })
        #expect(b1.activity?.since == nil, "idle seats report no eventAt")
    }
}

@Suite struct VersionGateTests {
    @Test(arguments: ["0.7.11", "0.7.0", "0.7.99-beta.1"])
    func tested(semver: String) {
        #expect(DaemonHealth(status: "ok", semver: semver).compatibility == .tested)
    }

    @Test(arguments: ["0.8.0", "0.6.9", "1.0.0"])
    func untested(semver: String) {
        #expect(DaemonHealth(status: "ok", semver: semver).compatibility == .untested(semver))
    }

    @Test func missingOrGarbledVersionIsUnknown() {
        #expect(DaemonHealth(status: "ok").compatibility == .unknown)
        #expect(DaemonHealth(status: "ok", semver: "dev").compatibility == .unknown)
    }
}

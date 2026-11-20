import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

@Suite struct RigLineTests {
    @Test func runningShowsUptime() throws {
        let rigs = try RigFixtures.decode("ps", as: [RigSummary].self)
        let line = rigLine(try #require(rigs.first))
        #expect(line == RigLine(tone: .running, text: "up 1d 16h · 7 seats"))
    }

    @Test func eachLifecycle() {
        func line(_ lifecycle: RigLifecycle, running: Int, snapshot: String? = nil) -> RigLine {
            rigLine(
                RigSummary(
                    id: "r", name: "r", lifecycle: lifecycle, nodeCount: 7, runningCount: running,
                    latestSnapshot: snapshot))
        }
        #expect(line(.degraded, running: 6) == RigLine(tone: .attention, text: "degraded · 6 of 7 seats"))
        #expect(line(.attentionRequired, running: 7) == RigLine(tone: .needsYou, text: "needs you"))
        let one = RigSummary(
            id: "r", name: "r", lifecycle: .attentionRequired, nodeCount: 2, runningCount: 2, attentionCount: 1)
        #expect(
            rigLine(one) == RigLine(tone: .needsYou, text: "needs you · 1 seat"),
            "counts seats needing you, not seats up")
        #expect(line(.recoverable, running: 0) == RigLine(tone: .attention, text: "stopped unexpectedly · 7 seats"))
        #expect(
            line(.stopped, running: 0, snapshot: "2h ago") == RigLine(tone: .stopped, text: "stopped · snapshot 2h ago")
        )
        #expect(line(.stopped, running: 0) == RigLine(tone: .stopped, text: "stopped"))
        #expect(
            line(.running, running: 6) == RigLine(tone: .running, text: "6 of 7 seats"), "one seat stopped on purpose")
        #expect(line(RigLifecycle(rawValue: "new"), running: 0) == RigLine(tone: .stopped, text: "0/7 running"))
    }

    @Test func stoppedMeansNothingRuns() {
        #expect(isStopped(RigSummary(id: "r", name: "r", status: .stopped, nodeCount: 3)))
        #expect(!isStopped(RigSummary(id: "r", name: "r", status: .partial, nodeCount: 3, runningCount: 1)))
        #expect(!isStopped(RigSummary(id: "r", name: "r", status: .running, nodeCount: 3, runningCount: 3)))
    }
}

@Suite struct PlainReasonTests {
    @Test func reasons() {
        #expect(plainReason("generation_mismatch") == "no report since restart")
        #expect(plainReason("idle_status_bar") == "idle status bar")
    }
}

@Suite struct RigProgressTests {
    private func seat(_ id: String, startup: String? = nil, status: SeatStatus = .running, state: ActivityState = .idle)
        -> Seat
    {
        Seat(id: id, logicalId: id, status: status, startupStatus: startup, activity: AgentActivity(state: state))
    }

    @Test func pendingSeatsAreStarting() {
        #expect(presence(seat("a", startup: "pending")) == .starting)
        #expect(!SeatPresence.starting.needsYou)
        // Before its session exists a launching seat can read as detached; it is still starting.
        #expect(presence(seat("a", startup: "pending", status: .detached)) == .starting)
    }

    @Test func startCountsSeatsUp() {
        let graph = RigGraph(seats: [
            seat("a", startup: "ready"), seat("b", startup: "pending"), seat("c", status: .exited),
        ])
        #expect(startProgress(graph) == StartProgress(up: 1, total: 3))
    }

    @Test func stopNamesSeatsMidTurn() throws {
        let graph = RigGraph(seats: [
            seat("a", state: .running), seat("b"), seat("c", status: .exited, state: .running),
        ])
        let risk = stopRisk(graph)
        #expect(risk.working.map(\.id) == ["a"], "a seat that's down isn't interrupted")
        #expect(risk.idle == 1)
        #expect(risk.live == 2)
    }

    /// Recorded from a throwaway rig right after `rig down`.
    @Test func recordedStoppedRig() throws {
        let rig = try #require(try RigFixtures.decode("ps-stopped", as: [RigSummary].self).first)
        #expect(isStopped(rig))
        #expect(rigLine(rig).tone == .stopped)
        let graph = try RigFixtures.decode("graph-stopped", as: RigGraph.self)
        #expect(graph.seats.allSatisfy { presence($0) == .exited })
        #expect(stopRisk(graph).live == 0)
        #expect(needsYouEntries(prompts: [], seats: graph.seats, items: []).isEmpty, "a stopped rig asks nothing")
    }

    /// Recorded half a second into `rig up --existing`: one seat launching, one not yet.
    @Test func recordedStartingRig() throws {
        let graph = try RigFixtures.decode("graph-starting", as: RigGraph.self)
        #expect(graph.seats.map(presence).sorted { "\($0)" < "\($1)" } == [.exited, .starting])
        #expect(startProgress(graph) == StartProgress(up: 0, total: 2))
    }

    @Test func recordedRigIsAllUp() throws {
        let graph = try RigFixtures.decode("graph-denkeeper", as: RigGraph.self)
        let progress = startProgress(graph)
        #expect(progress.up == progress.total)
    }
}

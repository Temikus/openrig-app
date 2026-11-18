import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

@Suite struct PresenceTests {
    /// Recorded from a test rig seconds after its seat's tmux session was killed: the daemon still says
    /// `status: running`, but the activity reason is `session_missing`.
    @Test func killedSessionReadsAsLost() throws {
        let graph = try RigFixtures.decode("graph-lost", as: RigGraph.self)
        let seat = try #require(graph.seats.first)
        #expect(seat.status == .running)
        #expect(seat.startupStatus == "attention_required")
        #expect(presence(seat) == .lost)
    }

    @Test func liveFixturesHaveNoLostSeats() throws {
        for name in ["graph-denkeeper", "graph-kernel"] {
            let graph = try RigFixtures.decode(name, as: RigGraph.self)
            #expect(graph.seats.allSatisfy { presence($0) == .live }, "\(name)")
        }
    }

    @Test func sessionStatuses() {
        #expect(presence(Seat(id: "a", logicalId: "a", status: .detached)) == .lost)
        #expect(presence(Seat(id: "a", logicalId: "a", status: .exited)) == .exited)
        #expect(presence(Seat(id: "a", logicalId: "a", status: .failed)) == .failed)
        #expect(presence(Seat(id: "a", logicalId: "a", startupStatus: "failed")) == .failed)
        #expect(presence(Seat(id: "a", logicalId: "a", status: SeatStatus(rawValue: "unknown"))) == .live, "no claim")
    }

    @Test func needsYouOrder() throws {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        func prompt(_ id: String, at: Date) throws -> PromptInstance {
            let seat = Seat(id: id, logicalId: id, sessionName: "\(id)@r")
            let stop = PermissionStop(state: .requestObserved, command: "ls", observedAt: at, actor: "main")
            return try #require(PromptInstance(seat: seat, stop: stop))
        }
        let lost = Seat(id: "dead", logicalId: "dead", sessionName: "dead@r", status: .detached)
        let exited = Seat(id: "off", logicalId: "off", sessionName: "off@r", status: .exited)
        let held = item("q-held", .blocked, from: "lead@r", to: "dev@r", blockedOn: "external:decision")

        let entries = needsYouEntries(
            prompts: [try prompt("late", at: seen + 60), try prompt("early", at: seen)],
            seats: [lost, exited], items: [held])
        // The prompt that has stalled its turn longest comes first; a stopped seat isn't an ask.
        #expect(entries.map(\.id) == ["prompt:early", "prompt:late", "seat:dead", "qitem:q-held"])
    }
}

import Foundation
import RigDomain
import RigModel
import RigTerminal
import Testing

@testable import RigClient

/// The app's Start Rig, Stop Rig and Resume Seat, run through the real CLI against a throwaway rig. Opt-in only:
/// `just test-lifecycle <rig>` sets OPENRIG_TEST_RIG. It stops the whole rig and kills one seat's tmux session, so
/// never point it at a rig anyone is using.
@Suite(
    .serialized,
    .enabled("set OPENRIG_TEST_RIG=<throwaway rig> (just test-lifecycle)") {
        guard ProcessInfo.processInfo.environment["OPENRIG_TEST_RIG"] != nil else { return false }
        return await RigCLI.find() != nil
    })
struct LiveLifecycleTests {
    let rigName = ProcessInfo.processInfo.environment["OPENRIG_TEST_RIG"] ?? ""
    let http = DaemonHTTP(baseURL: DaemonLocator().locate().baseURL)

    @Test(.timeLimit(.minutes(3))) func stopStartAndResumeOneSeat() async throws {
        let me = Human.address(in: try? await http.participants())
        let cli = try #require(await RigCLI.find(actor: me))
        let tmux = try #require(Tmux.locate())
        let id = try #require(try await http.rigs().first { $0.name == rigName }?.id, "no rig named \(rigName)")

        // Stop: the rig reads stopped and every seat exited.
        let down = try await cli.run(.rigDown(rig: rigName))
        #expect(down.succeeded, "\(down.stderr)")
        let stopped = try await waitFor("rig stopped") { try await summary(id).map(isStopped) == true }
        #expect(stopped)
        #expect(try await summary(id)?.lifecycle == .stopped)
        #expect(try await http.graph(rigID: id).seats.allSatisfy { presence($0) == .exited })

        // Start: every seat comes back up.
        let up = try await cli.run(.rigUp(rig: rigName))
        #expect(up.succeeded, "\(up.stderr)")
        let started = try await waitFor("every seat live") {
            let graph = try await http.graph(rigID: id)
            return startProgress(graph).up == graph.seats.count
        }
        #expect(started)

        // Resume one killed seat; its siblings keep their tmux sessions.
        let graph = try await http.graph(rigID: id)
        let target = try #require(graph.seats.first { $0.sessionName != nil })
        let siblings = graph.seats.filter { $0.id != target.id }.compactMap(\.sessionName)
        let before = try await sessionIDs(siblings, tmux)
        _ = try await tmux.run(["kill-session", "-t", "=\(target.sessionName ?? "")"])
        let lost = try await waitFor("seat lost") {
            try await http.graph(rigID: id).seats.first { $0.id == target.id }.map(presence) == .lost
        }
        #expect(lost)

        let launch = try await cli.run(.launchSeat(rig: rigName, logicalId: target.logicalId))
        #expect(launch.succeeded, "\(launch.stderr)")
        let back = try await waitFor("seat live again") {
            try await http.graph(rigID: id).seats.first { $0.id == target.id }.map(presence) == .live
        }
        #expect(back)
        #expect(try await sessionIDs(siblings, tmux) == before, "a sibling seat was restarted")
    }

    private func summary(_ id: String) async throws -> RigSummary? {
        try await http.rigs().first { $0.id == id }
    }

    private func sessionIDs(_ sessions: [String], _ tmux: Tmux) async throws -> [String] {
        var ids: [String] = []
        for session in sessions {
            ids.append(try await tmux.run(["display-message", "-p", "-t", "=\(session):", "#{session_id}"]))
        }
        return ids
    }

    /// Polls every second for up to 30 s; the daemon notices a killed session within a few seconds.
    private func waitFor(_ what: String, _ check: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<30 {
            if try await check() { return true }
            try await Task.sleep(for: .seconds(1))
        }
        Issue.record("timed out waiting for \(what)")
        return false
    }
}

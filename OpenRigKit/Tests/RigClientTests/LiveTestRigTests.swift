import Foundation
import RigModel
import Testing

@testable import RigClient

/// The app's own write actions, run as the app's person against a throwaway seat. Opt-in only:
/// `just test-rig <seat>` sets OPENRIG_TEST_SEAT. It messages that seat's agent, so never point it at a real rig.
@Suite(
    .serialized,
    .enabled("set OPENRIG_TEST_SEAT=<seat>@<throwaway rig> (just test-rig)") {
        ProcessInfo.processInfo.environment["OPENRIG_TEST_SEAT"] != nil && RigCLI.locate() != nil
    })
struct LiveTestRigTests {
    let seat = ProcessInfo.processInfo.environment["OPENRIG_TEST_SEAT"] ?? ""

    @Test(.timeLimit(.minutes(1))) func everyWriteIsRecordedAsThePerson() async throws {
        let base = DaemonLocator().locate().baseURL
        let http = DaemonHTTP(baseURL: base)
        let me = Human.address(in: try? await http.participants())
        let cli = try #require(RigCLI.locate(actor: me))

        let created = try await cli.run(
            .create(
                destination: seat, summary: "OpenRig.app live test: leave this row to the test",
                body: "Created, blocked, resolved and closed by OpenRigKit's LiveTestRigTests. No action needed.",
                priority: .routine))
        #expect(created.succeeded, "\(created.stderr)")
        let id = try #require(created.stdout.firstMatch(of: /qitem-[0-9A-Za-z-]+/).map { String($0.output) })

        let blocked = try await cli.run(
            .block(id: id, on: "external:openrig-app-test", wakeAfter: "1h", note: "Waiting on the live test"))
        #expect(blocked.succeeded, "\(blocked.stderr)")
        #expect(try await http.qitem(id: id).state == .blocked)

        let resolved = try await cli.run(.resolve(id: id, decision: "Resolved by the live test"))
        #expect(resolved.succeeded, "\(resolved.stderr)")
        #expect(try await http.qitem(id: id).state == .inProgress)

        let closed = try await cli.run(.close(id: id, reason: .noFollowOn, target: nil, resolution: "live test done"))
        #expect(closed.succeeded, "\(closed.stderr)")
        #expect(try await http.qitem(id: id).state == .done)

        // Each step names the person as its actor, never the TUI's pane.
        let log = try await cli.run(arguments: ["queue", "transitions", id, "--json"])
        let actors = try JSONDecoder().decode([Transition].self, from: Data(log.stdout.utf8)).map(\.actorSession)
        #expect(actors.count >= 4)
        #expect(actors.allSatisfy { $0 == me }, "\(actors)")

        let sent = try await cli.run(.send(session: seat, text: "OpenRig.app live test: no reply needed."))
        #expect(sent.succeeded, "\(sent.stderr)")
    }

    private struct Transition: Decodable {
        var actorSession: String?
    }
}

import Foundation
import Testing

@testable import RigClient

/// Writes to the real queue. Opt-in only: `just test-live` sets OPENRIG_LIVE_WRITES=1.
/// It touches nothing but one qitem it creates from the human seat to itself, with no nudge,
/// and closes it before finishing.
@Suite(
    .serialized,
    .enabled("set OPENRIG_LIVE_WRITES=1 (just test-live)") {
        ProcessInfo.processInfo.environment["OPENRIG_LIVE_WRITES"] == "1" && RigCLI.locate() != nil
    })
struct LiveWriteTests {
    let me = "operator-human@kernel"

    @Test(.timeLimit(.minutes(1))) func actionsComeBackThroughTheEventStream() async throws {
        let cli = try #require(RigCLI.locate(actor: me))
        let base = DaemonLocator().locate().baseURL
        let events = Recorder()
        let listener = Task {
            for await update in EventStream(baseURL: base).updates() {
                if case .event(let e) = update { events.add(e) }
            }
        }
        defer { listener.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        // Create: raw args, because the app's Queue task always nudges and this must not.
        let created = try await cli.run(
            arguments: [
                "queue", "create", "--destination", me, "--summary", "openrig-app live test", "--body-file", "-",
                "--no-nudge", "--json",
            ], stdin: "Created by OpenRigKit's LiveWriteTests; closed by the same test.")
        #expect(created.succeeded, "\(created.stderr)")
        let id = try #require(created.stdout.firstMatch(of: /qitem-[0-9A-Za-z-]+/).map { String($0.output) })
        try await events.waitFor(type: "queue.created", id: id)

        let noted = try await cli.run(.note(id: id, text: "note from the live test"))
        #expect(noted.succeeded, "\(noted.stderr)")
        try await events.waitFor(type: "queue.updated", id: id)

        let closed = try await cli.run(.close(id: id, reason: .canceled, target: nil, resolution: "live test done"))
        #expect(closed.succeeded, "\(closed.stderr)")
        let row = try await DaemonHTTP(baseURL: base).qitem(id: id)
        #expect(row.state == .done)
        #expect(row.closureReason == "canceled")
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [DaemonEvent] = []
    func add(_ e: DaemonEvent) { lock.withLock { seen.append(e) } }

    /// The plan's bar: the action shows up on the stream within a second.
    func waitFor(type: String, id: String) async throws {
        for _ in 0..<20 {
            let hit = lock.withLock {
                seen.contains { $0.type == type && String(decoding: $0.data, as: UTF8.self).contains(id) }
            }
            if hit { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("no \(type) event for \(id) within 1 s")
    }
}

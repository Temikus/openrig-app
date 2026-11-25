import Foundation
import Testing

@testable import RigClient
@testable import RigModel

// Contract tests against the local daemon. The HTTP API is internal and undocumented,
// so these catch shape drift that the recorded fixtures cannot. They only read.
enum LiveDaemon {
    static let client = DaemonHTTP(baseURL: DaemonLocator().locate().baseURL, timeout: 2)

    static func isRunning() async -> Bool {
        (try? await client.health()) != nil
    }
}

@Suite(.enabled("needs a running rig daemon") { await LiveDaemon.isRunning() })
struct LiveDaemonTests {
    let client = LiveDaemon.client

    @Test func health() async throws {
        let health = try await client.health()
        #expect(health.isHealthy)
        #expect(health.semver?.isEmpty == false)
    }

    @Test func everyRigAndItsGraphDecode() async throws {
        let rigs = try await client.rigs()
        for rig in rigs where !rig.isArchived {
            let graph = try await client.graph(rigID: rig.id)
            #expect(graph.seats.count == rig.nodeCount, "\(rig.name)")
            let podIDs = Set(graph.pods.map(\.id))
            for seat in graph.seats {
                #expect(seat.podID.map(podIDs.contains) == true, "\(rig.name)/\(seat.logicalId) has no pod")
                #expect(seat.sessionName != nil, "\(rig.name)/\(seat.logicalId) has no session name")
            }
            let seatIDs = Set(graph.seats.map(\.id))
            #expect(graph.edges.allSatisfy { seatIDs.contains($0.source) && seatIDs.contains($0.target) })
        }
    }

    /// The app's rig refresh relies on the daemon applying `rig` and `state` together.
    @Test func openRowsOfARigAreOpenAndInTheRig() async throws {
        let open: Set<QItemState> = [.pending, .inProgress, .blocked]
        for rig in try await client.rigs() where !rig.isArchived {
            let rows = try await client.openRows(rig: rig.name)
            for row in rows {
                #expect(open.contains(row.state), "\(rig.name): \(row.id) is \(row.state.rawValue)")
                #expect(
                    row.source.hasSuffix("@\(rig.name)") || row.destination.hasSuffix("@\(rig.name)"),
                    "\(rig.name): \(row.id) is \(row.source) → \(row.destination)")
            }
        }
    }

    /// History is topped up with `updatedSince`: every row returned is closed and updated at or after the time asked.
    @Test func closedRowsAreClosedAndUpdatedSinceTheTimeAsked() async throws {
        let since = Date.now.addingTimeInterval(-24 * 3600)
        for rig in try await client.rigs() where !rig.isArchived {
            let rows = try await client.closedRows(rig: rig.name, since: since)
            for row in rows {
                #expect(
                    !([.pending, .inProgress, .blocked] as Set<QItemState>).contains(row.state),
                    "\(rig.name): \(row.id) is \(row.state.rawValue)")
                #expect(
                    row.updated.map { $0 >= since.addingTimeInterval(-0.001) } == true,
                    "\(rig.name): \(row.id) updated \(String(describing: row.updated))")
            }
            let updated = rows.compactMap(\.updated)
            #expect(updated == updated.sorted(by: >), "\(rig.name): not newest-updated first")
        }
    }

    @Test func unknownRigIs404() async throws {
        await #expect(throws: DaemonError.http(status: 404, path: "/api/rigs/no-such-rig/graph")) {
            try await client.graph(rigID: "no-such-rig")
        }
    }
}

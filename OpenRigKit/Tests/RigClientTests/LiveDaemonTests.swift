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

    @Test func unknownRigIs404() async throws {
        await #expect(throws: DaemonError.http(status: 404, path: "/api/rigs/no-such-rig/graph")) {
            try await client.graph(rigID: "no-such-rig")
        }
    }
}

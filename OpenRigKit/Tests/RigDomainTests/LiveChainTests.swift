import Foundation
import RigClient
import RigModel
import Testing

@testable import RigDomain

/// Contract check against the local daemon: chains rebuilt from list rows must match
/// what `GET /api/queue/:id` (and so `rig queue show`) reports. Read-only.
@Suite(.enabled("needs a running rig daemon") { (try? await liveClient().health())?.isHealthy == true })
struct LiveChainTests {
    @Test func reconstructedChainsMatchTheDaemon() async throws {
        let client = liveClient()
        let rigs = try await client.rigs()
        var checked = 0
        for rig in rigs where !rig.isArchived {
            let rows = try await client.queue(rigName: rig.name)
            let index = ChainIndex(rows)
            // The three rows with the longest recorded chains in this rig.
            let tails = rows.filter { ($0.chainOfRecord?.count ?? 0) > 0 }
                .sorted { $0.chainOfRecord!.count > $1.chainOfRecord!.count }
                .prefix(3)
            for tail in tails {
                let shown = try await client.qitem(id: tail.id)
                let chain = index.chain(for: tail.id)
                #expect(Array(chain.ids.prefix(chain.focusIndex)) == shown.chainOfRecord, "\(rig.name) \(tail.id)")
                checked += 1
            }
        }
        if checked == 0 { print("LiveChainTests: no handoff chains on this daemon; nothing compared") }
    }
}

private func liveClient() -> DaemonHTTP {
    DaemonHTTP(baseURL: DaemonLocator().locate().baseURL, timeout: 3)
}

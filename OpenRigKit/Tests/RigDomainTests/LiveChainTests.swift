import Foundation
import RigClient
import RigModel
import Testing

@testable import RigDomain

/// Contract check against the local daemon: chains rebuilt from list rows must match
/// what `GET /api/queue/:id` (and so `rig queue show`) reports. Read-only. Opt-in: on a busy daemon its reads
/// outlast the 3 s timeout, so `just test` would fail at random. `just test-live` sets OPENRIG_LIVE_READS=1.
@Suite(
    .enabled("set OPENRIG_LIVE_READS=1 (just test-live)") {
        // The variable first, so a default run never contacts the daemon.
        guard ProcessInfo.processInfo.environment["OPENRIG_LIVE_READS"] == "1" else { return false }
        return (try? await liveClient().health())?.isHealthy == true
    })
struct LiveChainTests {
    @Test func reconstructedChainsMatchTheDaemon() async throws {
        let client = liveClient()
        let rigs = try await client.rigs()
        var checked = 0
        for rig in rigs where !rig.isArchived {
            let rows = try await client.queue(rigName: rig.name)
            let index = ChainIndex(rows)
            // The three rows with the longest recorded chains in this rig.
            let tails = rows.filter { !qitemIDs($0.chainOfRecord).isEmpty }
                .sorted { qitemIDs($0.chainOfRecord).count > qitemIDs($1.chainOfRecord).count }
                .prefix(3)
            for tail in tails {
                let shown = try await client.qitem(id: tail.id)
                let chain = index.chain(for: tail.id)
                #expect(
                    Array(chain.ids.prefix(chain.focusIndex)) == qitemIDs(shown.chainOfRecord), "\(rig.name) \(tail.id)"
                )
                checked += 1
            }
        }
        if checked == 0 { print("LiveChainTests: no handoff chains on this daemon; nothing compared") }
    }
}

/// The daemon also records reroutes in `chainOfRecord` (`fallback-from:<session>` when a seat is removed).
/// Chains link qitems only.
private func qitemIDs(_ record: [String]?) -> [String] {
    (record ?? []).filter {
        if case .qitem = Blocker(ref: $0) { true } else { false }
    }
}

private func liveClient() -> DaemonHTTP {
    DaemonHTTP(baseURL: DaemonLocator().locate().baseURL, timeout: 3)
}

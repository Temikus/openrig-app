import Foundation
import Observation
import RigClient
import RigModel

/// Daemon status, the rig list and the selected rig's graph.
/// M0 polls; the SSE event stream replaces most of this in M1.
@MainActor @Observable
final class AppStore {
    enum DaemonState: Equatable {
        case connecting
        case running(DaemonHealth)
        case unreachable(reason: String, since: Date)
    }

    private(set) var endpoint: DaemonEndpoint
    private(set) var daemon: DaemonState = .connecting
    private(set) var rigs: [RigSummary] = []
    private(set) var graphs: [RigSummary.ID: RigGraph] = [:]
    private(set) var graphError: String?
    private(set) var lastUpdated: Date?
    var selectedRigID: RigSummary.ID? {
        didSet { if selectedRigID != oldValue { Task { await refreshGraph() } } }
    }

    private let locator: DaemonLocator
    private var client: DaemonHTTP

    init(locator: DaemonLocator = DaemonLocator()) {
        self.locator = locator
        let endpoint = locator.locate()
        self.endpoint = endpoint
        self.client = DaemonHTTP(baseURL: endpoint.baseURL, timeout: 3)
    }

    var selectedRig: RigSummary? { rigs.first { $0.id == selectedRigID } }
    var selectedGraph: RigGraph? { selectedRigID.flatMap { graphs[$0] } }

    /// Runs until the calling task is cancelled: health every 5 s, rigs and graph every 15 s.
    func run() async {
        var tick = 0
        while !Task.isCancelled {
            let wasUp = isUp
            await refreshHealth()
            if isUp && (!wasUp || tick % 3 == 0) {
                await refreshRigs()
                await refreshGraph()
            }
            tick += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refreshNow() async {
        await refreshHealth()
        guard isUp else { return }
        await refreshRigs()
        await refreshGraph()
    }

    private var isUp: Bool {
        if case .running = daemon { true } else { false }
    }

    private func refreshHealth() async {
        // daemon.json changes when the daemon restarts on another port.
        let located = locator.locate()
        if located.baseURL != endpoint.baseURL {
            endpoint = located
            client = DaemonHTTP(baseURL: located.baseURL, timeout: 3)
        }
        do {
            daemon = .running(try await client.health())
        } catch {
            if case .unreachable = daemon { return }
            daemon = .unreachable(reason: Self.describe(error), since: .now)
        }
    }

    private func refreshRigs() async {
        guard let rigs = try? await client.rigs() else { return }
        self.rigs = rigs.filter { !$0.isArchived }
        lastUpdated = .now
        if selectedRigID == nil || !self.rigs.contains(where: { $0.id == selectedRigID }) {
            selectedRigID = self.rigs.first?.id
        }
    }

    private func refreshGraph() async {
        guard let id = selectedRigID else { return }
        do {
            graphs[id] = try await client.graph(rigID: id)
            graphError = nil
        } catch {
            graphError = Self.describe(error)
        }
    }

    private static func describe(_ error: DaemonError) -> String {
        switch error {
        case .unreachable(let message): message
        case .http(let status, let path): "HTTP \(status) from \(path)"
        case .decoding(let path, _): "Unexpected response from \(path)"
        }
    }
}

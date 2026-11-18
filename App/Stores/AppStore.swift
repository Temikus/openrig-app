import Foundation
import Observation
import RigClient
import RigModel

enum ViewMode: String, CaseIterable, Identifiable {
    case canvas, queue, terminals
    var id: Self { self }
    var title: String {
        switch self {
        case .canvas: "Canvas"
        case .queue: "Queue board"
        case .terminals: "Terminals"
        }
    }
}

/// Daemon status, the rig list, and the store for the selected rig.
/// Event-stream messages are refresh signals: the stores refetch state over HTTP.
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
    /// True while the event stream is connected; otherwise the views rely on polling.
    private(set) var isLive = false
    private(set) var rig: RigStore?
    let selection = SelectionStore()
    var viewMode: ViewMode = .canvas

    var selectedRigID: RigSummary.ID? {
        didSet {
            guard selectedRigID != oldValue else { return }
            selection.clear()
            rig = selectedRigID.map { id in
                RigStore(rigID: id, rigName: rigs.first { $0.id == id }?.name ?? id, client: client)
            }
            Task { await rig?.refresh() }
        }
    }

    private let locator: DaemonLocator
    private var client: DaemonHTTP
    private var rigsRefresh: Task<Void, Never>?

    init(locator: DaemonLocator = DaemonLocator()) {
        self.locator = locator
        let endpoint = locator.locate()
        self.endpoint = endpoint
        self.client = DaemonHTTP(baseURL: endpoint.baseURL, timeout: 3)
    }

    var selectedRig: RigSummary? { rigs.first { $0.id == selectedRigID } }

    var isUp: Bool {
        if case .running = daemon { true } else { false }
    }

    /// Health every 5 s; rigs and graph every 15 s as a safety net behind the event stream.
    func runPolling() async {
        var tick = 0
        while !Task.isCancelled {
            let wasUp = isUp
            await refreshHealth()
            if isUp && (!wasUp || tick % 3 == 0) {
                await refreshRigs()
                await rig?.refresh()
            }
            tick += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Follows `/api/events` until cancelled, restarting when the daemon moves.
    func runEvents() async {
        while !Task.isCancelled {
            let url = endpoint.baseURL
            for await update in EventStream(baseURL: url).updates() {
                switch update {
                case .connected:
                    isLive = true
                case .disconnected:
                    isLive = false
                case .event(let event):
                    handle(event)
                }
                if endpoint.baseURL != url { break }
            }
            isLive = false
        }
    }

    func refreshNow() async {
        await refreshHealth()
        guard isUp else { return }
        await refreshRigs()
        await rig?.refresh()
    }

    private func handle(_ event: DaemonEvent) {
        if let rigId = event.rigId, rigId != selectedRigID {
            if event.type.hasPrefix("rig.") { scheduleRigsRefresh() }
            return
        }
        switch event.type.split(separator: ".").first ?? "" {
        case "snapshot", "watchdog":
            return
        case "rig":
            scheduleRigsRefresh()
            rig?.scheduleRefresh()
        default:
            // seat.*, agent.*, node.* and queue.* change what the graph shows.
            rig?.scheduleRefresh()
            if event.type == "seat.activity_changed" { rig?.terminals.poke() }
        }
    }

    private func scheduleRigsRefresh() {
        rigsRefresh?.cancel()
        rigsRefresh = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await refreshRigs()
        }
    }

    private func refreshHealth() async {
        // daemon.json changes when the daemon restarts on another port.
        let located = locator.locate()
        if located.baseURL != endpoint.baseURL {
            endpoint = located
            client = DaemonHTTP(baseURL: located.baseURL, timeout: 3)
            rig?.client = client
        }
        do {
            daemon = .running(try await client.health())
        } catch {
            if case .unreachable = daemon { return }
            daemon = .unreachable(reason: error.userMessage, since: .now)
        }
    }

    private func refreshRigs() async {
        guard let rigs = try? await client.rigs() else { return }
        self.rigs = rigs.filter { !$0.isArchived }
        if selectedRigID == nil || !self.rigs.contains(where: { $0.id == selectedRigID }) {
            selectedRigID = self.rigs.first?.id
        }
    }
}

extension DaemonError {
    var userMessage: String {
        switch self {
        case .unreachable(let message): message
        case .http(let status, let path): "HTTP \(status) from \(path)"
        case .decoding(let path, _): "Unexpected response from \(path)"
        }
    }
}

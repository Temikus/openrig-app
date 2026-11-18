import AppKit
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
    /// "⌘1"…: the menu shortcut that switches to this view.
    var shortcutHint: String { "⌘\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
    var systemImage: String {
        switch self {
        case .canvas: "point.3.connected.trianglepath.dotted"
        case .queue: "rectangle.split.3x1"
        case .terminals: "terminal"
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
    let actions = ActionStore()
    /// Who the app acts as; see `Human.address(in:)`.
    private(set) var me = Human.session
    var viewMode: ViewMode = .canvas

    var selectedRigID: RigSummary.ID? {
        didSet {
            guard selectedRigID != oldValue else { return }
            selection.clear()
            rig = selectedRigID.map { id in
                RigStore(rigID: id, rigName: rigs.first { $0.id == id }?.name ?? id, client: client)
            }
            rig?.me = me
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

    /// `rig daemon start`, then a fresh look once it answers.
    func startDaemon() async {
        if await actions.perform(.startDaemon, key: "daemon", success: "Daemon started", allowOffline: true) {
            await refreshNow()
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
            actions.offline = false
        } catch {
            actions.offline = true
            if case .unreachable = daemon { return }
            daemon = .unreachable(reason: error.userMessage, since: .now)
        }
    }

    private func refreshRigs() async {
        guard let rigs = try? await client.rigs() else { return }
        await refreshIdentity()
        self.rigs = rigs.filter { !$0.isArchived }
        if selectedRigID == nil || !self.rigs.contains(where: { $0.id == selectedRigID }) {
            selectedRigID = self.rigs.first?.id
            #if DEBUG
                await openDebugTarget()
            #endif
        }
    }

    /// Registering a person (`rig gateway human add … --default`) takes effect without a relaunch.
    private func refreshIdentity() async {
        guard let gateway = try? await client.participants() else { return }
        let address = Human.address(in: gateway)
        guard address != me else { return }
        me = address
        actions.act(as: address)
        rig?.me = address
    }

    #if DEBUG
        /// OPENRIG_DEBUG_OPEN="<rig>[/<canvas|queue|terminals>][/<session or qitem id>][/typing]" opens that view at launch,
        /// for screenshots when the UI can't be clicked (a locked screen, CI).
        private func openDebugTarget() async {
            // OPENRIG_DEBUG_APPEARANCE=dark|light overrides the system appearance.
            switch ProcessInfo.processInfo.environment["OPENRIG_DEBUG_APPEARANCE"] {
            case "dark"?: NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light"?: NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            // OPENRIG_DEBUG_SIZE="<width>x<height>" resizes the window once launch has settled, as a person would.
            if let size = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SIZE"]?.split(separator: "x"),
                size.count == 2, let w = Double(size[0]), let h = Double(size[1]),
                let window = NSApp.windows.first(where: \.isVisible)
            {
                try? await Task.sleep(for: .seconds(3))
                window.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: true)
            }
            guard let spec = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_OPEN"] else { return }
            let parts = spec.split(separator: "/").map(String.init)
            guard let rig = rigs.first(where: { $0.name == parts.first }) else { return }
            selectedRigID = rig.id
            if parts.count > 1, let mode = ViewMode(rawValue: parts[1]) { viewMode = mode }
            guard parts.count > 2, let store = self.rig else { return }
            await store.refresh()
            if let seat = store.seat(session: parts[2]) {
                selection.select(seat: seat, in: store)
                if viewMode == .terminals {
                    store.terminals.focus(seat)
                    store.terminals.typing = parts.count > 3 && parts[3] == "typing"
                }
            } else if store.item(parts[2]) != nil {
                selection.select(qitem: parts[2])
            }
        }
    #endif
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

import AppKit
import Foundation
import Observation
import RigClient
import RigDomain
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
    /// Open rows addressed to the person on every rig, refreshed with the rig list.
    private var rowsForMe: [QItem] = []
    /// Whether each view shows the inspector, remembered across switches. Terminals starts without it, since
    /// its tiles carry each seat's state.
    var inspectorByMode: [ViewMode: Bool] = [.terminals: false]
    /// Bumped to show the inspector in the current view, e.g. so a row opened from another rig shows its answer panel.
    private(set) var inspectorRequests = 0
    /// Those sent from other rigs than the selected one, which its queue doesn't list.
    var elsewhere: [QItem] {
        let known = Set(rigs.map(\.name))
        return forYouElsewhere(rowsForMe, me: me, excluding: rig?.rigName).filter {
            rigName(ofSession: $0.source).map(known.contains) ?? false
        }
    }
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
            // Another rig's queue may have a new row for the person.
            if event.type.hasPrefix("rig.") || event.type.hasPrefix("queue.") { scheduleRigsRefresh() }
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
            // A row answered here may also be listed for the person; refresh so it doesn't come back elsewhere.
            if event.type.hasPrefix("queue.") { scheduleRigsRefresh() }
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
        await refreshRowsForMe()
        self.rigs = rigs.filter { !$0.isArchived }
        if selectedRigID == nil || !self.rigs.contains(where: { $0.id == selectedRigID }) {
            selectedRigID = self.rigs.first?.id
            #if DEBUG
                await openDebugTarget()
            #endif
        }
    }

    private func refreshRowsForMe() async {
        // The registered person, plus the unnamed one that older replies still address.
        let addresses = ([me] + Human.unnamed).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let client = client
        let found = await withTaskGroup(of: [QItem]?.self) { group in
            for address in addresses { group.addTask { try? await client.openRows(to: address) } }
            var all: [[QItem]?] = []
            for await rows in group { all.append(rows) }
            return all
        }
        // Keep what we had if any request failed, rather than flashing rows away.
        guard !found.contains(where: { $0 == nil }) else { return }
        var rows: [QItem] = []
        for row in found.compactMap(\.self).joined() where !rows.contains(where: { $0.id == row.id }) {
            rows.append(row)
        }
        rows.sort { $0.id < $1.id }
        if rows != rowsForMe { rowsForMe = rows }
    }

    /// What waits on the person in a rig, for its sidebar row. The selected rig counts its Needs-you list; another rig
    /// counts rows addressed to the person plus the daemon's count of seats needing attention (prompts, which the
    /// app only polls for the selected rig).
    func waiting(in summary: RigSummary) -> Waiting {
        if summary.id == selectedRigID, let rig { return RigDomain.waiting(rig.needsYou, me: me) }
        let rows = rowsForMe.filter { rigName(ofSession: $0.source) == summary.name }
        return RigDomain.waiting(rows: rows, me: me, attention: summary.attentionCount)
    }

    /// Everything waiting on the person, every rig: the toolbar's Needs-you count, equal to the sidebar's sum.
    var waitingEverywhere: Waiting { rigs.map(waiting(in:)).reduce(Waiting(), +) }

    /// Other rigs with seats needing the person (their prompts aren't polled), for Needs you's per-rig groups.
    var attentionElsewhere: [(rig: String, count: Int)] {
        rigs.filter { $0.id != selectedRigID && $0.attentionCount > 0 }.map { ($0.name, $0.attentionCount) }
    }

    /// Shows a rig's canvas, where its seats needing attention are marked.
    func open(rigNamed name: String) {
        guard let target = rigs.first(where: { $0.name == name }) else { return }
        selectedRigID = target.id
        viewMode = .canvas
    }

    /// Shows a row from another rig: selects that rig, opens its queue board and the row.
    func open(_ item: QItem) {
        guard let name = rigName(ofSession: item.source), let target = rigs.first(where: { $0.name == name }) else {
            return
        }
        // Before the switch, which restores the queue's remembered inspector state.
        inspectorByMode[.queue] = true
        selectedRigID = target.id
        viewMode = .queue
        selection.select(qitem: item.id)
        // Already on the queue board: the switch restores nothing.
        inspectorRequests += 1
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
            // OPENRIG_DEBUG_SIZE="<width>x<height>[,<width>x<height>…]" resizes the window once launch has settled,
            // as a person would, then to each later size 3 s apart.
            if let window = NSApp.windows.first(where: \.isVisible) {
                for spec in (ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SIZE"] ?? "").split(separator: ",") {
                    let size = spec.split(separator: "x")
                    guard size.count == 2, let w = Double(size[0]), let h = Double(size[1]) else { continue }
                    try? await Task.sleep(for: .seconds(3))
                    window.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: true)
                }
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

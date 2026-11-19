import AppKit
import Foundation
import Observation
import RigClient
import RigDomain
import RigModel
import RigTerminal

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
    /// Who the app acts as: Settings' pick when the gateway still has that person, else `Human.address(in:)`.
    private(set) var me = Human.session
    /// The gateway's people, for Settings › General › Act as.
    private(set) var gateway: GatewayParticipants?
    var people: [String] { gateway?.participants.filter { $0.kind == "person" }.map(\.address) ?? [] }
    /// Open rows addressed to the person on every rig, refreshed with the rig list.
    private var rowsForMe: [QItem] = []
    /// Whether each view shows the inspector, remembered across switches. Terminals starts without it, since
    /// its tiles carry each seat's state.
    var inspectorByMode: [ViewMode: Bool] = [.terminals: false]
    /// Set by ⌘F; the queue board focuses its search field and clears it. A flag, not an event, because the board may
    /// only appear after the switch to it.
    var wantsSearch = false
    /// Bumped to show the inspector in the current view, e.g. so a row opened from another rig shows its answer panel.
    private(set) var inspectorRequests = 0
    /// Those sent from other rigs than the selected one, which its queue doesn't list.
    var elsewhere: [QItem] {
        let known = Set(rigs.map(\.name))
        return forYouElsewhere(rowsForMe, me: me, excluding: rig?.rigName).filter {
            rigName(ofSession: $0.source).map(known.contains) ?? false
        }
    }
    var viewMode: ViewMode = .canvas {
        didSet { settings.lastView = viewMode }
    }
    let settings: AppSettings
    /// The operator bearer from the Keychain, sent by both the HTTP client and the CLI.
    private(set) var token: String?
    /// Whether the daemon's operator gate accepts the token (or no token), for Settings › Connection.
    private(set) var tokenCheck: DaemonHTTP.OperatorAuth?

    var selectedRigID: RigSummary.ID? {
        didSet {
            guard selectedRigID != oldValue else { return }
            selection.clear()
            rig = selectedRigID.map { id in
                RigStore(rigID: id, rigName: rigs.first { $0.id == id }?.name ?? id, client: client, tmux: tmux())
            }
            if let name = rig?.rigName { settings.lastRigName = name }
            rig?.me = me
            Task { await rig?.refresh() }
        }
    }

    private var locator: DaemonLocator
    private var client: DaemonHTTP
    private var rigsRefresh: Task<Void, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var banners: Banners?
    /// The main window is open and frontmost; set by ContentView. Banners can wait while it is.
    var windowInFront = false

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let locator = DaemonLocator(override: settings.customAddress)
        self.locator = locator
        let endpoint = locator.locate()
        self.endpoint = endpoint
        client = DaemonHTTP(baseURL: endpoint.baseURL, timeout: 3)
        viewMode = settings.launchView
        actions.http = client
        actions.use(cli())
    }

    /// Starts polling and the event stream for the life of the app, not of a window: banners, the menu bar item and
    /// the Dock badge keep working with the window closed.
    func start() {
        guard loops.isEmpty else { return }
        banners = Banners(store: self)
        loops = [Task { await runPolling() }, Task { await runEvents() }]
        Task { await loadToken() }
        // NSApp exists once the run loop has started.
        Task { NSApp.appearance = settings.appearance.nsAppearance }
        #if DEBUG
            // OPENRIG_DEBUG_SHOW="<seconds>|<rig>|<session>" does what clicking a seat's banner does, then logs the
            // selection (OPENRIG_DEBUG_BANNERS), to check the click path without a click.
            let parts = (ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SHOW"] ?? "").split(separator: "|")
            if parts.count == 3, let delay = Double(parts[0]) {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    show(.seat(rig: String(parts[1]), session: String(parts[2])))
                    for _ in 0..<4 {
                        try? await Task.sleep(for: .seconds(2))
                        Banners.debugLog("after show: seat \(selection.seatID ?? "nil"), rig \(rig?.rigName ?? "nil")")
                    }
                }
            }
        #endif
    }

    /// After each poll: the Dock badge and any new banners.
    private func afterPoll() async {
        let urgent = waitingEverywhere.urgent
        let label = settings.dockBadge && urgent > 0 ? "\(urgent)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        #if DEBUG
            // OPENRIG_DEBUG_BADGE=<file> records each poll's Dock badge, to check it with the window closed.
            if let path = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_BADGE"] {
                try? "\(Date.now.formatted(.iso8601)) \(NSApp.dockTile.badgeLabel ?? "none")\n"
                    .appendLine(to: path)
            }
        #endif
        await banners?.check()
    }

    /// Opens the app where a banner points.
    func show(_ target: NoticeTarget) {
        showMainWindow()
        switch target {
        case .seat(let rigName, let session):
            open(rigNamed: rigName)
            Task {
                guard let store = rig else { return }
                await store.refresh()
                guard let seat = store.seat(session: session) else {
                    Banners.debugLog("show: no seat \(session) in \(store.rigName)")
                    return
                }
                Banners.debugLog("show: selected \(session)")
                inspectorByMode[.canvas] = true
                selection.select(seat: seat, in: store)
                inspectorRequests += 1
            }
        case .qitem(let id):
            if rig?.item(id) != nil {
                inspectorByMode[.queue] = true
                viewMode = .queue
                selection.select(qitem: id)
                inspectorRequests += 1
            } else if let row = rowsForMe.first(where: { $0.id == id }) {
                open(row)
            }
        case .rig(let name):
            open(rigNamed: name)
        case .app:
            break
        }
    }

    /// Brings the main window forward, reopening it if it was closed: opening the running app's bundle sends the
    /// reopen event, which makes SwiftUI create a window.
    func showMainWindow() {
        NSApp.activate()
        if !windowInFront, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain && $0.frame.width >= 800 })
        {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    /// Re-reads Settings › Connection: address, token and tool picks. The next poll uses them.
    func applyConnectionSettings() {
        locator = DaemonLocator(override: settings.customAddress)
        endpoint = locator.locate()
        client = DaemonHTTP(baseURL: endpoint.baseURL, timeout: 3, bearer: token)
        rig?.client = client
        actions.http = client
        actions.use(cli())
        if let id = selectedRigID {
            rig = RigStore(rigID: id, rigName: rig?.rigName ?? id, client: client, tmux: tmux())
            rig?.me = me
        }
        daemon = .connecting
        Task {
            await loadToken()
            await refreshNow()
            await checkToken()
        }
    }

    /// Asks the daemon's operator gate about the current token, changing nothing (see `checkOperatorAuth`).
    func checkToken() async {
        tokenCheck = await client.checkOperatorAuth(as: me)
    }

    /// Reads the token off the main thread: the Keychain may ask the person first (after a rebuild changes an ad-hoc
    /// signature, or for an item another tool wrote), and that wait must not freeze the app.
    func loadToken() async {
        let read = await Task.detached { OperatorToken.read() }.value
        guard read != token else { return }
        token = read
        client.bearer = read
        rig?.client = client
        actions.http = client
        actions.use(cli())
    }

    /// The rig CLI as Settings describes it: the picked or found executable, aimed at the same daemon as the app.
    private func cli() -> RigCLI? {
        guard let rig = ToolLocator.resolve(override: settings.rigPath, searchPaths: RigCLI.searchPaths) else {
            return nil
        }
        return RigCLI(
            executable: rig.url, actor: me,
            daemonURL: settings.customAddress.flatMap { DaemonLocator.normalized($0.absoluteString) },
            bearer: token, extraPath: settings.nodePath?.deletingLastPathComponent().path)
    }

    private func tmux() -> Tmux? {
        Tmux.locate(openRigHome: locator.openRigHome, executable: settings.tmuxPath)
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
            await afterPoll()
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
            client = DaemonHTTP(baseURL: located.baseURL, timeout: 3, bearer: token)
            rig?.client = client
            actions.http = client
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
            let last = settings.reopenLastRig ? self.rigs.first { $0.name == settings.lastRigName } : nil
            selectedRigID = (last ?? self.rigs.first)?.id
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
        self.gateway = gateway
        applyIdentity()
    }

    /// Re-reads Settings › General › Act as.
    func applyIdentity() {
        let picked = settings.actAs.flatMap { people.contains($0) || Human.isYou($0) ? $0 : nil }
        let address = picked ?? Human.address(in: gateway)
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
            if ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SETTINGS"] != nil {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        case .refused(_, let message): message
        }
    }
}

#if DEBUG
    extension String {
        fileprivate func appendLine(to path: String) throws {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(utf8))
            } else {
                try write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
#endif

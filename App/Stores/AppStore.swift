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

enum RigOp: Equatable {
    case starting, stopping
}

/// A command-line tool the app runs, and where to look for it when the shell's PATH doesn't have it.
enum Tool: String {
    case rig, tmux, node

    var fallback: [String] {
        switch self {
        case .rig: RigCLI.searchPaths
        case .tmux: Tmux.searchPaths
        case .node: ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        }
    }

    @MainActor func override(in settings: AppSettings) -> URL? {
        switch self {
        case .rig: settings.rigPath
        case .tmux: settings.tmuxPath
        case .node: settings.nodePath
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

    /// The relay forwards to this daemon and acts through it, so it follows every change: a daemon on another
    /// machine turns it off, and it never forwards to an old address.
    private(set) var endpoint: DaemonEndpoint {
        didSet {
            guard endpoint.baseURL != oldValue.baseURL else { return }
            let url = endpoint.baseURL
            Task { await relay.refresh(daemon: url) }
        }
    }
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
    /// Open rows addressed to the person on every rig, and every rig's blocked rows (some held on the person). Read
    /// on the poll, and on events about such a row.
    private var rowsForMe: [QItem] = []
    private let rowsForMeRefresh = GatedRefresh()
    /// Read for `rowsForMe`, and matched against event destinations.
    private var addresses: [String] { Human.addresses(of: me) }
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
            rig = selectedRigID.map { id in makeRigStore(id: id, name: rigs.first { $0.id == id }?.name ?? id) }
            if let name = rig?.rigName { settings.lastRigName = name }
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
    /// Relays paired phones' calls to the daemon; it outlives the Settings window.
    let relay = RelayStore()

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
        rowsForMeRefresh.work = { [weak self] in await self?.refreshRowsForMe() }
    }

    /// Starts polling and the event stream for the life of the app, not of a window: banners, the menu bar item and
    /// the Dock badge keep working with the window closed.
    func start() {
        guard loops.isEmpty else { return }
        banners = Banners(store: self)
        loops = [Task { await runPolling() }, Task { await runEvents() }]
        Task { await loadToken() }
        Task { await loadShellPath() }
        relay.desk = MacRelayDesk(store: self)
        Task { await relay.refresh(daemon: endpoint.baseURL) }
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

    /// Shows a seat of the selected rig, picked from a Needs-you row: its tile on Terminals, else the seat in the
    /// inspector, which opens if it was hidden. A selection alone changed nothing visible on Terminals.
    func reveal(seat: Seat, in store: RigStore) {
        selection.select(seat: seat, in: store)
        if viewMode == .terminals { store.terminals.focus(seat) } else { inspectorRequests += 1 }
    }

    /// Shows a row of the selected rig in the inspector, which opens if it was hidden.
    func reveal(qitem id: QItem.ID) {
        selection.select(qitem: id)
        inspectorRequests += 1
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
        if let id = selectedRigID { rig = makeRigStore(id: id, name: rig?.rigName ?? id) }
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

    /// The folders on the person's shell PATH, read once after launch (`ShellPath`). Empty until then, or when the
    /// shell can't tell; tools are then found only in the usual install places, as before.
    private(set) var shellPath: [String] = []

    /// Reads the shell's PATH off the main thread (a login shell takes a second or so), then finds the tools again.
    func loadShellPath() async {
        let found = await ShellPath.load()
        guard found != shellPath else { return }
        shellPath = found
        actions.use(cli())
        // A RigStore keeps the tmux it was made with; replace it only if the shell found a different one.
        if let id = selectedRigID, let rig, rig.terminals.tmux?.executable != tmux()?.executable {
            self.rig = makeRigStore(id: id, name: rig.rigName)
            Task { await self.rig?.refresh() }
        }
    }

    /// A store for rig `id` with the current client, tmux, actor and pending Start or Stop.
    private func makeRigStore(id: RigSummary.ID, name: String) -> RigStore {
        let store = RigStore(rigID: id, rigName: name, client: client, tmux: tmux())
        store.me = me
        store.op = rigOps[id]
        return store
    }

    /// Where `tool` is: the person's pick in Settings, else the first on their shell's PATH, else the usual install
    /// places. A pick that has gone gives nil.
    func locate(_ tool: Tool) -> ToolLocation? {
        ToolLocator.resolve(
            override: tool.override(in: settings),
            searchPaths: ToolLocator.searchPaths(for: tool.rawValue, shellPath: shellPath, fallback: tool.fallback))
    }

    /// The rig CLI as Settings describes it: the picked or found executable, aimed at the same daemon as the app.
    private func cli() -> RigCLI? {
        guard let rig = locate(.rig) else { return nil }
        return RigCLI(
            executable: rig.url, actor: me,
            daemonURL: settings.customAddress.flatMap { DaemonLocator.normalized($0.absoluteString) },
            bearer: token, extraPath: settings.nodePath?.deletingLastPathComponent().path, shellPath: shellPath)
    }

    func tmux() -> Tmux? {
        Tmux.locate(
            openRigHome: locator.openRigHome, executable: settings.tmuxPath,
            searchPaths: ToolLocator.searchPaths(for: "tmux", shellPath: shellPath, fallback: Tmux.searchPaths))
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
            if isUp && (!wasUp || tick % 3 == 0) { await refreshEverything() }
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

    /// Start can help only when the address was found automatically (daemon.json or the default port). An address
    /// set in Settings or OPENRIG_URL may be another machine or port, where `rig daemon start` changes nothing.
    var canStartDaemon: Bool {
        switch endpoint.source {
        case .stateFile, .fallback: true
        case .custom, .environment: false
        }
    }

    var isUnreachable: Bool {
        if case .unreachable = daemon { true } else { false }
    }

    /// host:port, as people type it in Settings › Connection.
    var daemonAddress: String {
        let url = endpoint.baseURL
        return [url.host(percentEncoded: false), url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }

    /// Rigs with a `rig up` or `rig down` in flight. Kept here, not on RigStore, so it survives switching rigs.
    private(set) var rigOps: [RigSummary.ID: RigOp] = [:]
    /// The ActionStore key for a rig's start or stop, so its result shows next to the control.
    static func rigKey(_ id: RigSummary.ID) -> String { "rig:\(id)" }

    /// The last start or stop that failed, per rig, so the failure banner can name it and try it again.
    private(set) var failedOps: [RigSummary.ID: RigOp] = [:]
    /// Rigs started from here that aren't fully up yet; "<rig> is up" is announced when they are.
    @ObservationIgnored private var awaitingUp: Set<RigSummary.ID> = []

    /// `rig up <rig> --existing`. Seats light up on the canvas as their startup events arrive.
    func startRig(_ summary: RigSummary) async {
        // `rig up` returns before the harnesses are ready, so this says seats are starting, not that the rig is up.
        await run(.starting, on: summary, .rigUp(rig: summary.name), success: "Starting \(summary.name)'s seats")
    }

    /// `rig down <rig>`, after the person confirmed in the stop popover.
    func stopRig(_ summary: RigSummary) async {
        await run(.stopping, on: summary, .rigDown(rig: summary.name), success: "\(summary.name) stopped")
    }

    private func run(_ op: RigOp, on summary: RigSummary, _ action: RigAction, success: String) async {
        guard rigOps[summary.id] == nil else { return }
        setOp(op, for: summary.id)
        announce(op == .starting ? "Starting \(summary.name)" : "Stopping \(summary.name)")
        let ok = await actions.perform(action, key: Self.rigKey(summary.id), success: success)
        failedOps[summary.id] = ok ? nil : op
        if ok && op == .starting { awaitingUp.insert(summary.id) }
        setOp(nil, for: summary.id)
        await refreshNow()
    }

    /// Retries the start or stop that failed.
    func retry(_ summary: RigSummary) async {
        switch failedOps[summary.id] {
        case .starting?: await startRig(summary)
        case .stopping?: await stopRig(summary)
        case nil: break
        }
    }

    /// Clears a failed start or stop and its message.
    func dismissFailure(_ id: RigSummary.ID) {
        failedOps[id] = nil
        actions.clear(Self.rigKey(id))
    }

    /// After each rig list refresh: a start's "is up", and results that no longer describe the rig.
    private func noteLifecycleChanges(from old: [RigSummary]) {
        for rig in rigs {
            if awaitingUp.contains(rig.id), rig.nodeCount > 0, rig.runningCount == rig.nodeCount {
                awaitingUp.remove(rig.id)
                announce("\(rig.name) is up, \(rig.nodeCount) \(rig.nodeCount == 1 ? "seat" : "seats")")
            }
            // A success line outlives its moment once the rig changes state on its own (a crash, a CLI stop).
            guard rigOps[rig.id] == nil, let before = old.first(where: { $0.id == rig.id }),
                before.lifecycle != rig.lifecycle, case .succeeded? = actions.status[Self.rigKey(rig.id)]
            else { continue }
            actions.clear(Self.rigKey(rig.id))
        }
    }

    private func setOp(_ op: RigOp?, for id: RigSummary.ID) {
        rigOps[id] = op
        if rig?.rigID == id { rig?.op = op }
    }

    /// `rig daemon start`, then a fresh look once it answers.
    func startDaemon() async {
        if await actions.perform(.startDaemon, key: "daemon", success: "Daemon started", allowOffline: true) {
            await refreshNow()
        }
    }

    /// Reads everything now, skipping the refresh gates: health, the rig list, the person's rows and the selected rig.
    func refreshNow() async {
        await refreshHealth()
        guard isUp else { return }
        await refreshEverything()
    }

    /// The poll's reads, and `refreshNow()`'s once the daemon answers. Returns when all have finished.
    private func refreshEverything() async {
        await refreshRigs()
        await rowsForMeRefresh.now()
        await rig?.refresh()
    }

    /// Re-reads only what the event can change (`eventReach`).
    private func handle(_ event: DaemonEvent) {
        var place = EventPlace(type: event.type, payload: event.data)
        place.rigId = place.rigId ?? event.rigId
        let rig = rig
        // Only the rows the person sees: rowsForMe also holds every rig's blocked rows, and most are agents' chains.
        let mine = Set(RigDomain.humanQueue(rowsForMe, me: me).map(\.id))
        let context = EventContext(
            rigID: rig?.rigID, rigName: rig?.rigName, seatIDs: Set(rig?.graph?.seats.map(\.id) ?? []),
            holdsRow: { rig?.item($0) != nil }, addresses: Set(addresses), holdsRowForMe: mine.contains)
        let reach = eventReach(place, in: context)
        if reach.contains(.refreshRig) { rig?.scheduleRefresh() }
        if reach.contains(.pokeTerminals) { rig?.terminals.poke() }
        if reach.contains(.refreshRigList) { scheduleRigsRefresh() }
        if reach.contains(.refreshRowsForMe) { rowsForMeRefresh.event() }
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
            let health = try await client.health()
            if case .unreachable = daemon { announce("Daemon reconnected") }
            daemon = .running(health)
            actions.offline = false
        } catch {
            actions.offline = true
            if case .unreachable = daemon { return }
            if case .running = daemon { announce("Daemon stopped. Showing the last data, read-only.", urgent: true) }
            daemon = .unreachable(reason: error.userMessage, since: .now)
        }
    }

    /// The rig list and who the person is. Rows for the person are read separately, behind their own gate.
    private func refreshRigs() async {
        guard let rigs = try? await client.rigs() else { return }
        await refreshIdentity()
        let old = self.rigs
        self.rigs = rigs.filter { !$0.isArchived }
        noteLifecycleChanges(from: old)
        if selectedRigID == nil || !self.rigs.contains(where: { $0.id == selectedRigID }) {
            let last = settings.reopenLastRig ? self.rigs.first { $0.name == settings.lastRigName } : nil
            selectedRigID = (last ?? self.rigs.first)?.id
            #if DEBUG
                await openDebugTarget()
                Task { await AccessibilityDump.run() }
            #endif
        }
    }

    /// Run only by `rowsForMeRefresh`, so two reads never overlap.
    private func refreshRowsForMe() async {
        let addresses = addresses
        let client = client
        let found = await withTaskGroup(of: [QItem]?.self) { group in
            for address in addresses { group.addTask { try? await client.openRows(to: address) } }
            group.addTask { try? await client.blockedRows() }
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
    /// counts its rows waiting on the person plus the daemon's count of seats needing attention (prompts, which the
    /// app only polls for the selected rig).
    func waiting(in summary: RigSummary) -> Waiting {
        if summary.id == selectedRigID, let rig { return RigDomain.waiting(rig.needsYou, me: me, rig: summary.name) }
        // A row to the person counts in its sender's rig; a held row in its owner's.
        let rows = rowsForMe.filter { rigName(ofSession: askedBy($0, me: me)) == summary.name }
        return RigDomain.waiting(rows: rows, me: me, attention: summary.attentionCount)
    }

    /// Everything waiting on the person, every rig: the toolbar's Needs-you count, equal to the sidebar's sum.
    var waitingEverywhere: Waiting { rigs.map(waiting(in:)).reduce(Waiting(), +) }

    /// Other rigs with seats needing the person (their prompts aren't polled), for Needs you's per-rig groups.
    var attentionElsewhere: [(rig: String, count: Int)] {
        rigs.filter { $0.id != selectedRigID && $0.attentionCount > 0 }.map { ($0.name, $0.attentionCount) }
    }

    /// Every rig's asks of the person, for the Needs You window. Rows from rigs the daemon no longer lists drop out.
    var humanQueue: [QItem] {
        let known = Set(rigs.map(\.name))
        return RigDomain.humanQueue(rowsForMe, me: me).filter {
            rigName(ofSession: askedBy($0, me: me)).map(known.contains) ?? false
        }
    }

    /// The store for the rig an ask came from: the selected rig's own, else a new one the caller refreshes.
    func rigStore(named name: String) -> RigStore? {
        if rig?.rigName == name { return rig }
        return rigs.first { $0.name == name }.map { makeRigStore(id: $0.id, name: $0.name) }
    }

    /// Open the seat: its rig on Terminals in the main window, with the seat's tile focused.
    func openSeat(session: String) {
        guard let name = rigName(ofSession: session) else { return }
        showMainWindow()
        open(rigNamed: name)
        viewMode = .terminals
        Task {
            guard let store = rig, store.rigName == name else { return }
            await store.refresh()
            if let seat = store.seat(session: session) { reveal(seat: seat, in: store) }
        }
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
        /// OPENRIG_DEBUG_OPEN="<rig>[/<canvas|queue|terminals>][/<session or qitem id>][/typing][/history]" opens that view at launch,
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
                    // A scroll up over the focused tile, as a person would.
                    if parts.last == "history" {
                        try? await Task.sleep(for: .seconds(2))
                        store.terminals.showHistory(seat)
                    }
                }
            } else if !parts[2].contains("@") {
                // Selected even when not held (closed, or another rig's): the rig store reads a selected row by id.
                selection.select(qitem: parts[2])
            }
        }
    #endif
}

/// Runs `work` one at a time, as a `RefreshGate` allows: events wait for the gate, `now()` skips its gap.
@MainActor
private final class GatedRefresh {
    var work: () async -> Void = {}
    private var gate = RefreshGate()
    private var driver: Task<Void, Never>?
    /// The driver's sleep until the gate opens; cancelled when a new request may move the start earlier.
    private var wait: Task<Void, Never>?
    /// Callers of `now()` waiting for a run that starts after their request.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func event() { ask(.event) }

    /// Returns once a run that started after this call has finished.
    func now() async {
        await withCheckedContinuation { waiter in
            waiters.append(waiter)
            ask(.now)
        }
    }

    private func ask(_ request: RefreshGate.Request) {
        gate.request(request, at: .now)
        wait?.cancel()
        if driver == nil { driver = Task { await drive() } }
    }

    private func drive() async {
        while let due = gate.nextStart {
            if due > .now {
                let sleep = Task { _ = try? await Task.sleep(until: due, clock: .continuous) }
                wait = sleep
                await sleep.value
                wait = nil
                continue
            }
            guard gate.start(at: .now) else { continue }
            let served = waiters
            waiters = []
            await work()
            gate.finish()
            served.forEach { $0.resume() }
        }
        driver = nil
    }
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

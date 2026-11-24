import CoreGraphics
import Foundation
import Observation
import RigCanvasLayout
import RigClient
import RigDomain
import RigModel
import RigTerminal

/// One rig's graph and queue, plus the canvas geometry derived from them.
@MainActor @Observable
final class RigStore {
    let rigID: String
    let rigName: String
    var client: DaemonHTTP
    /// The app's own address, from AppStore.
    var me = Human.session
    /// A start or stop of this rig in flight, mirrored from AppStore.
    var op: RigOp?

    private(set) var graph: RigGraph?
    /// This rig's rows: open ones, today's closed ones while a view holds them, and rows read by id.
    private(set) var items: [QItem] = []
    /// Every held row by id, rows of other rigs read by id included (a selected row, an ancestor).
    private(set) var rowsByID: [QItem.ID: QItem] = [:]
    private(set) var chains = ChainIndex([])
    /// Today's closed rows, for the board's Today scope and ⌘K.
    private(set) var closedRows: ClosedRows = .off
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var layout: CanvasLayout?
    /// Each Claude seat's permission stop, refreshed with the graph.
    private(set) var stops: [Seat.ID: PermissionStop] = [:]
    /// Active workflow instances bound to this rig; they give a packet's planned next hop.
    private(set) var workflows: [WorkflowInstance] = []
    let terminals: TerminalStore
    #if DEBUG
        private let launched = Date.now
    #endif
    /// The OPENRIG_DEBUG_ROW rows the last refresh added (a real row with the same id wins).
    private var madeUpIDs: Set<QItem.ID> = []

    /// A row from OPENRIG_DEBUG_ROW: it never posts a banner, and nothing on it reaches a seat (ActionStore refuses).
    func isMadeUp(_ id: QItem.ID) -> Bool { madeUpIDs.contains(id) }

    /// Seat heights measured by the canvas. Layout depends on them, so changes re-run layout.
    private var seatSizes: [String: CGSize] = [:]
    /// The rows as read. Views see them only through `publish()`, so a refresh shows no half-merged state.
    @ObservationIgnored private var held = HeldRows()
    @ObservationIgnored private var gate = RefreshGate()
    @ObservationIgnored private var driver: Task<Void, Never>?
    /// The driver's wait for the gate; cancelled when a new request may move the next start earlier.
    @ObservationIgnored private var wait: Task<Void, Never>?
    /// Callers of `refresh()` waiting for a refresh that starts after their request.
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    // Routing depends on the selected qitem's chain; cache one result per selection.
    @ObservationIgnored private var routeCache: [String: RouteResult] = [:]

    init(rigID: String, rigName: String, client: DaemonHTTP, tmux: Tmux?) {
        self.rigID = rigID
        self.rigName = rigName
        self.client = client
        terminals = TerminalStore(tmux: tmux)
    }

    func seat(_ id: Seat.ID?) -> Seat? {
        guard let id else { return nil }
        return graph?.seats.first { $0.id == id }
    }

    func seat(session: String) -> Seat? {
        graph?.seats.first { $0.sessionName == session }
    }

    func item(_ id: QItem.ID?) -> QItem? {
        id.flatMap { rowsByID[$0] }
    }

    /// The seat's short name, or the session's name part for seats outside this rig. The app's own address reads "You".
    func displayName(session: String) -> String {
        if session == me || Human.isYou(session) { return "You" }
        return seat(session: session)?.displayName ?? String(session.split(separator: "@").first ?? Substring(session))
    }

    /// Open permission prompts, in seat order.
    var prompts: [PromptInstance] {
        (graph?.seats ?? []).compactMap { seat in stops[seat.id].flatMap { PromptInstance(seat: seat, stop: $0) } }
    }

    var needsYou: [NeedsYouEntry] { needsYouEntries(prompts: prompts, seats: graph?.seats ?? [], items: items, me: me) }

    /// The prompt as drawn on the seat's pane: the only place the command is visible
    /// (the daemon reports "Bash: details withheld").
    func promptScreen(for seatID: Seat.ID) async -> PromptScreen? {
        guard let tmux = terminals.tmux, let pane = seat(seatID)?.tmuxPane,
            let lines = try? await tmux.screen(pane: pane)
        else { return nil }
        return PromptScreen(lines: lines)
    }

    /// Each seat's launch folder, or nil when the daemon couldn't say (seat gone, daemon down or slow). Kept 30 s:
    /// a restarted seat may have a new folder, and a slow daemon isn't asked again for every row.
    @ObservationIgnored private var launchFolders: [String: (folder: String?, at: Date)] = [:]

    func launchFolder(session: String) async -> String? {
        guard daemonIsLocal else { return nil }
        if let known = launchFolders[session], Date.now.timeIntervalSince(known.at) < 30 { return known.folder }
        let folder = try? await client.seatStatus(session: session).launchCwd
        launchFolders[session] = (folder, .now)
        return folder
    }

    /// The daemon runs on this Mac, so a row's paths name this Mac's files. (DaemonLocator's settings check is
    /// separate; ios-remote changes that file.)
    var daemonIsLocal: Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(client.baseURL.host()?.lowercased() ?? "")
    }

    /// The images `item` points at; relative paths resolve only with a launch folder. Reads the disk off the main thread.
    func images(for item: QItem, launchFolder folder: String?) async -> RowImages {
        let local = daemonIsLocal
        let (ref, body) = (item.evidenceRef, item.body)
        return await Task.detached(priority: .userInitiated) {
            RowImages.find(evidenceRef: ref, body: body, launchFolder: folder, local: local)
        }.value
    }

    /// Reads the seat's prompt now, bypassing the cached copy; used right before answering.
    func currentStop(session: String) async -> PermissionStop {
        (try? await client.seatStatus(session: session).permissionStop) ?? .unavailable
    }

    private func refreshStops(_ graph: RigGraph) async {
        let client = self.client
        let seats = graph.seats.filter { $0.runtime == "claude-code" && $0.sessionName != nil }
        let fresh = await withTaskGroup(of: (Seat.ID, PermissionStop).self) { group in
            for seat in seats {
                group.addTask {
                    (seat.id, (try? await client.seatStatus(session: seat.sessionName!).permissionStop) ?? .unavailable)
                }
            }
            var result: [Seat.ID: PermissionStop] = [:]
            for await (id, stop) in group { result[id] = stop }
            return result
        }
        var shown = fresh
        // A declined prompt sends no hook, so the daemon can report one that is already gone.
        // Trust the pane: list a prompt only while the seat's screen still shows one.
        for (id, stop) in fresh where stop.state == .requestObserved && terminals.tmux != nil {
            if await promptScreen(for: id) == nil { shown[id] = PermissionStop(state: .completed) }
        }
        #if DEBUG
            // OPENRIG_DEBUG_PROMPT="<session>|<command>[;<session>|<command>…]" shows fake prompts, to see the
            // control without a real one. Answering re-reads the real (absent) prompt, so nothing is sent.
            // OPENRIG_DEBUG_PROMPT_AFTER=<seconds> holds them back that long, so they arrive as new (for banners).
            let env = ProcessInfo.processInfo.environment
            let after = env["OPENRIG_DEBUG_PROMPT_AFTER"].flatMap(Double.init) ?? 0
            let specs = Date.now.timeIntervalSince(launched) >= after ? env["OPENRIG_DEBUG_PROMPT"] ?? "" : ""
            for (n, spec)
                in specs
                .split(separator: ";").enumerated()
            {
                guard let bar = spec.firstIndex(of: "|"),
                    let seat = graph.seats.first(where: { $0.sessionName == String(spec[..<bar]) })
                else { continue }
                shown[seat.id] = PermissionStop(
                    state: .requestObserved, command: String(spec[spec.index(after: bar)...]),
                    observedAt: launched - Double(n) * 60, actor: "main")
            }
        #endif
        if shown != stops { stops = shown }
    }

    // MARK: Refresh

    /// Refreshes now, skipping the gap between event refreshes: the person's own actions and the safety poll.
    /// Returns once a refresh that started after this call has finished. Never runs beside another refresh.
    func refresh() async {
        await withCheckedContinuation { waiter in
            waiters.append(waiter)
            ask(.now)
        }
    }

    /// A daemon event: a burst becomes one refresh, at most one every 2 s (`RefreshGate`).
    func scheduleRefresh() {
        ask(.event)
    }

    private func ask(_ request: RefreshGate.Request) {
        gate.request(request, at: .now)
        wait?.cancel()
        if driver == nil { driver = Task { await drive() } }
    }

    /// Runs refreshes as the gate allows, one at a time, until nothing is waiting.
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
            await load()
            gate.finish()
            served.forEach { $0.resume() }
        }
        driver = nil
    }

    private static let rowLimit = 500

    /// One refresh: the graph, the open rows, a top-up of today's closed rows while they are held, then the selected
    /// row. The top-up lands in the same pass as the open rows, so a row closing in between doesn't drop out.
    private func load() async {
        let since = held.topUpSince
        do {
            async let graphRead = client.graph(rigID: rigID)
            async let openRead = client.openRows(rig: rigName, limit: Self.rowLimit)
            async let closedRead = closedTopUp(since: since)
            let (fresh, open, closed) = try await (graphRead, openRead, closedRead)
            held.replaceOpen(open)
            if let closed {
                held.topUpClosed(closed)
                if closed.count >= Self.rowLimit, case .loaded = closedRows { closedRows = .loaded(cut: true) }
            }
            // After the open rows, which drop a selected row read by id once it is no longer open.
            await readSelected()
            error = nil
            lastUpdated = .now
            publish(graph: fresh)
            await refreshStops(fresh)
            await refreshWorkflows()
        } catch let error as DaemonError {
            self.error = error.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Nil when closed rows aren't held or the read failed; the next refresh tries again.
    private func closedTopUp(since: Date?) async -> [QItem]? {
        guard let since else { return nil }
        return try? await client.closedRows(rig: rigName, since: since, limit: Self.rowLimit)
    }

    /// Shows the held rows. Only this rig's rows are listed; rows of other rigs read by id are found by `item(_:)`.
    private func publish(graph fresh: RigGraph? = nil) {
        let all = held.all
        let (rows, added) = MadeUpRows.launch.merge(
            into: all.filter { [$0.source, $0.destination].contains { RigDomain.rigName(ofSession: $0) == rigName } })
        madeUpIDs = added
        let everything = all + rows.filter { added.contains($0.id) }
        let byID = Dictionary(everything.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = fresh ?? graph
        guard next != graph || rows != items || byID != rowsByID else { return }
        graph = next
        items = rows
        rowsByID = byID
        chains = ChainIndex(everything)
        recompute()
    }

    // MARK: The selected row

    /// The qitem the person selected, from the view. While it is not among the open or today's closed rows, each
    /// refresh reads it by id. Its ancestors that aren't held are read once.
    @ObservationIgnored var selectedQItemID: QItem.ID? {
        didSet {
            guard selectedQItemID != oldValue, selectedQItemID != nil else { return }
            Task {
                await readSelected()
                publish()
            }
        }
    }
    @ObservationIgnored private var askedAncestors: Set<QItem.ID> = []

    private func readSelected() async {
        guard let id = selectedQItemID else { return }
        let client = self.client
        if held.open[id] == nil, held.closed[id] == nil, !madeUpIDs.contains(id),
            let row = try? await client.qitem(id: id)
        {
            held.keep(row)
        }
        let missing = held.missingAncestors(of: id).filter { askedAncestors.insert($0).inserted }
        guard !missing.isEmpty else { return }
        let ancestors = await withTaskGroup(of: QItem?.self) { group in
            for ancestor in missing { group.addTask { try? await client.qitem(id: ancestor) } }
            var rows: [QItem] = []
            for await row in group { if let row { rows.append(row) } }
            return rows
        }
        ancestors.forEach { held.keep($0) }
    }

    // MARK: Today's closed rows

    enum ClosedRows: Equatable {
        case off, loading
        /// `cut`: the daemon returned as many rows as asked for, so some closed earlier today are missing.
        case loaded(cut: Bool)
        case failed(String)
    }

    /// Views holding closed rows. A count, not a set: a view's old hold can end after its new one began.
    @ObservationIgnored private var closedHolds = 0
    /// Counts closed reads, so one that lands after a newer read or a drop is ignored.
    @ObservationIgnored private var closedReads = 0

    /// Holds today's closed rows until the calling task is cancelled: call it from `.task`.
    func holdClosedRows() async {
        closedHolds += 1
        switch closedRows {
        case .off, .failed: loadClosedRows()
        case .loading, .loaded: break
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        closedHolds -= 1
        if closedHolds == 0 { dropClosedRows() }
    }

    /// Reads the rows closed since local midnight; also the Retry after a failed read. The read runs in its own
    /// task, so it outlives the view that asked when another view still holds the rows.
    func loadClosedRows() {
        closedReads += 1
        let read = closedReads
        closedRows = .loading
        let since = Calendar.current.startOfDay(for: .now)
        Task {
            do {
                let rows = try await client.closedRows(rig: rigName, since: since, limit: Self.rowLimit)
                guard read == closedReads else { return }
                held.replaceClosed(rows, since: since)
                // The daemon sorts by `updated`, newest first, and has no upper bound to page back with.
                closedRows = .loaded(cut: rows.count >= Self.rowLimit)
                publish()
            } catch {
                guard read == closedReads else { return }
                closedRows = .failed((error as? DaemonError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    private func dropClosedRows() {
        closedReads += 1
        // The selected row's chain stays held, so the inspector doesn't empty when the board leaves Today.
        if let id = selectedQItemID {
            for link in chains.chain(for: id).ids { if let row = held.closed[link] { held.keep(row) } }
        }
        held.dropClosed()
        closedRows = .off
        publish()
    }

    private func refreshWorkflows() async {
        // Older daemons have no workflow route; then there is simply no next hop.
        let all = (try? await client.workflows()) ?? []
        let mine = all.filter { $0.status == "active" && ($0.boundRig == nil || $0.boundRig == rigName) }
        if mine != workflows {
            workflows = mine
            routeCache = [:]
        }
    }

    /// Where the qitem goes when its owner closes it normally, if it is a workflow packet.
    func nextHop(for qitemID: QItem.ID) -> NextHop? {
        let runtimes = Dictionary(
            (graph?.seats ?? []).compactMap { seat in seat.sessionName.map { ($0, seat.runtime ?? "") } },
            uniquingKeysWith: { a, _ in a })
        return RigDomain.nextHop(for: qitemID, in: workflows, runtimeOf: { runtimes[$0] })
    }

    func reportHeight(_ height: CGFloat, for seat: Seat.ID) {
        guard abs((seatSizes[seat]?.height ?? -1) - height) > 0.5 else { return }
        seatSizes[seat] = CGSize(width: LayoutMetrics().seatWidth, height: height)
        if holdsLayout { heightsPending = true } else { recompute() }
    }

    /// The pointer is over the canvas, or VoiceOver is on a seat: a card growing for a prompt (or shrinking once it's
    /// answered) doesn't move the seats around it until both leave. Graph changes still lay out at once.
    var canvasHovered = false { didSet { releaseHeldLayout() } }
    var canvasVoiceOver = false { didSet { releaseHeldLayout() } }
    private var holdsLayout: Bool { canvasHovered || canvasVoiceOver }
    @ObservationIgnored private var heightsPending = false

    private func releaseHeldLayout() {
        guard !holdsLayout, heightsPending else { return }
        heightsPending = false
        recompute()
    }

    /// Spec edges, active work, and the selected item's past hops and planned next hop.
    func routes(selected: QItem.ID?) -> RouteResult {
        let key = selected ?? ""
        if let cached = routeCache[key] { return cached }
        guard let graph, let layout else { return RouteResult() }
        let chain = selected.map { chains.chain(for: $0) }
        let next = selected.flatMap(nextHop(for:))
        let result = routeCanvas(
            layout, spec: specWireRequests(for: graph),
            work: workWireRequests(items, graph: graph, chain: chain, next: next))
        routeCache[key] = result
        return result
    }

    private func recompute() {
        guard let graph else { return }
        heightsPending = false
        routeCache = [:]
        layout = layoutRig(layoutInput(for: graph, seatSizes: seatSizes))
    }
}

/// What the user has selected, shared by every view. Terminal focus (M3) is separate.
@MainActor @Observable
final class SelectionStore {
    enum Subject { case seat, qitem }

    var seatID: Seat.ID?
    var qitemID: QItem.ID?
    /// Which selection the inspector shows: the one made last.
    var inspecting: Subject = .seat

    func select(seat: Seat, in rig: RigStore) {
        seatID = seat.id
        inspecting = .seat
        if let session = seat.sessionName {
            qitemID = qitemSelection(afterSelecting: session, current: qitemID, in: rig.items)
        }
    }

    func select(qitem id: QItem.ID) {
        qitemID = id
        inspecting = .qitem
    }

    func clear() {
        seatID = nil
        qitemID = nil
    }
}

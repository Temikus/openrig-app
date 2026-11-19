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

    private(set) var graph: RigGraph?
    private(set) var items: [QItem] = []
    private(set) var chains = ChainIndex([])
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var layout: CanvasLayout?
    /// Each Claude seat's permission stop, refreshed with the graph.
    private(set) var stops: [Seat.ID: PermissionStop] = [:]
    /// Active workflow instances bound to this rig; they give a packet's planned next hop.
    private(set) var workflows: [WorkflowInstance] = []
    let terminals = TerminalStore()
    #if DEBUG
        private let launched = Date.now
    #endif

    /// Seat heights measured by the canvas. Layout depends on them, so changes re-run layout.
    private var seatSizes: [String: CGSize] = [:]
    private var pending: Task<Void, Never>?
    // Routing depends on the selected qitem's chain; cache one result per selection.
    @ObservationIgnored private var routeCache: [String: RouteResult] = [:]

    init(rigID: String, rigName: String, client: DaemonHTTP) {
        self.rigID = rigID
        self.rigName = rigName
        self.client = client
    }

    func seat(_ id: Seat.ID?) -> Seat? {
        guard let id else { return nil }
        return graph?.seats.first { $0.id == id }
    }

    func seat(session: String) -> Seat? {
        graph?.seats.first { $0.sessionName == session }
    }

    func item(_ id: QItem.ID?) -> QItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
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
            for (n, spec) in (ProcessInfo.processInfo.environment["OPENRIG_DEBUG_PROMPT"] ?? "")
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

    func refresh() async {
        do {
            async let graphRequest = client.graph(rigID: rigID)
            async let queueRequest = client.queue(rigName: rigName)
            let (fresh, rows) = try await (graphRequest, queueRequest)
            error = nil
            lastUpdated = .now
            if fresh != graph || rows != items {
                graph = fresh
                items = rows
                chains = ChainIndex(rows)
                recompute()
            }
            await refreshStops(fresh)
            await refreshWorkflows()
        } catch let error as DaemonError {
            self.error = error.userMessage
        } catch {
            self.error = error.localizedDescription
        }
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

    /// Coalesces bursts of events into one fetch.
    func scheduleRefresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func reportHeight(_ height: CGFloat, for seat: Seat.ID) {
        guard abs((seatSizes[seat]?.height ?? -1) - height) > 0.5 else { return }
        seatSizes[seat] = CGSize(width: LayoutMetrics().seatWidth, height: height)
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

import CoreGraphics
import Foundation
import Observation
import RigCanvasLayout
import RigClient
import RigDomain
import RigModel

/// One rig's graph and queue, plus the canvas geometry derived from them.
@MainActor @Observable
final class RigStore {
    let rigID: String
    let rigName: String
    var client: DaemonHTTP

    private(set) var graph: RigGraph?
    private(set) var items: [QItem] = []
    private(set) var chains = ChainIndex([])
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var layout: CanvasLayout?
    let terminals = TerminalStore()

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

    /// The seat's short name, or the session's name part for seats outside this rig.
    func displayName(session: String) -> String {
        seat(session: session)?.displayName ?? String(session.split(separator: "@").first ?? Substring(session))
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
        } catch let error as DaemonError {
            self.error = error.userMessage
        } catch {
            self.error = error.localizedDescription
        }
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

    /// Spec edges, active work, and past hops of the selected item's chain.
    func routes(selected: QItem.ID?) -> RouteResult {
        let key = selected ?? ""
        if let cached = routeCache[key] { return cached }
        guard let graph, let layout else { return RouteResult() }
        let chain = selected.map { chains.chain(for: $0) }
        let result = routeCanvas(
            layout, spec: specWireRequests(for: graph), work: workWireRequests(items, graph: graph, chain: chain))
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

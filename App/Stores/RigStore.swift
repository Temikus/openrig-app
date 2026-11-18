import CoreGraphics
import Foundation
import Observation
import RigCanvasLayout
import RigClient
import RigDomain
import RigModel

/// One rig's graph plus the canvas geometry derived from it.
@MainActor @Observable
final class RigStore {
    let rigID: String
    var client: DaemonHTTP

    private(set) var graph: RigGraph?
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var layout: CanvasLayout?
    private(set) var routes = RouteResult(wires: [], junctions: [])

    /// Seat heights measured by the canvas. Layout depends on them, so changes re-run layout and routing.
    private var seatSizes: [String: CGSize] = [:]
    private var pending: Task<Void, Never>?

    init(rigID: String, client: DaemonHTTP) {
        self.rigID = rigID
        self.client = client
    }

    func seat(_ id: Seat.ID?) -> Seat? {
        guard let id else { return nil }
        return graph?.seats.first { $0.id == id }
    }

    func refresh() async {
        do {
            let fresh = try await client.graph(rigID: rigID)
            error = nil
            lastUpdated = .now
            if fresh != graph {
                graph = fresh
                recompute()
            }
        } catch {
            self.error = error.userMessage
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

    private func recompute() {
        guard let graph else { return }
        let layout = layoutRig(layoutInput(for: graph, seatSizes: seatSizes))
        self.layout = layout
        routes = route(layout, specWireRequests(for: graph))
    }
}

/// What the user has selected. Separate from terminal focus (M3), as the design requires.
@MainActor @Observable
final class SelectionStore {
    var seatID: Seat.ID?

    func clear() {
        seatID = nil
    }
}

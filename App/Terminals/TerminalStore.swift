import Foundation
import Observation
import RigModel
import RigTerminal

/// Terminal state for one rig: pane snapshots for every tile, and the single attached client
/// for the focused tile. Focus is separate from selection, as the design requires.
@MainActor @Observable
final class TerminalStore {
    let tmux: Tmux?
    private(set) var snapshots: [String: PaneSnapshot] = [:]
    private(set) var focusedSeatID: Seat.ID?
    private(set) var attach: AttachSession?
    /// The attached client's grid.
    private(set) var attachSize: GridSize?
    /// Keys go straight to tmux only in Type mode. It resets on Esc and on focus moves.
    var typing = false
    /// Seats in display order, for ⌘] and ⌘[. Written by the grid as it lays out; not observed.
    @ObservationIgnored var order: [Seat.ID] = []

    @ObservationIgnored private var attachController: FocusedAttach?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?

    init(tmux: Tmux? = Tmux.locate()) {
        self.tmux = tmux
        attachController = tmux.map { FocusedAttach(tmux: $0) }
    }

    /// Snapshots every second, or sooner after `poke()`, until the calling task is cancelled.
    func run(panes: @escaping @MainActor () -> [String]) async {
        guard let tmux else { return }
        while !Task.isCancelled {
            snapshots = await tmux.snapshots(panes: panes())
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    wake = continuation
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        self.resume()
                    }
                }
            } onCancel: {
                Task { @MainActor in self.resume() }
            }
        }
    }

    /// Capture again now, e.g. after `seat.activity_changed`.
    func poke() { resume() }

    private func resume() {
        wake?.resume()
        wake = nil
    }

    func snapshot(_ seat: Seat) -> PaneSnapshot? {
        seat.tmuxPane.flatMap { snapshots[$0] }
    }

    /// The capture is older than 3 seconds: tmux stopped answering for this pane.
    func isStale(_ seat: Seat, now: Date) -> Bool {
        guard let snap = snapshot(seat) else { return true }
        return now.timeIntervalSince(snap.capturedAt) > 3
    }

    func focus(_ seat: Seat) {
        guard let session = seat.sessionName, let controller = attachController else { return }
        if focusedSeatID != seat.id { typing = false }
        let snap = snapshot(seat)
        // The client gets the pane's size plus the status bar, so the pane shows whole.
        let cols = snap?.cols ?? 80
        let rows = (snap?.rows ?? 24) + (snap?.statusRows ?? 0)
        attach = controller.focus(session: session, cols: cols, rows: rows)
        attachSize = attach.map { GridSize(cols: $0.size.cols, rows: $0.size.rows) }
        focusedSeatID = seat.id
    }

    /// Resizes the focused client to what its tile shows. Smaller than the pane, tmux shows the part
    /// around the cursor, which in Type mode is where the user is typing.
    func fitAttach(_ size: GridSize) {
        guard let attach, attachSize != size, size.cols > 0, size.rows > 1 else { return }
        // The view's grid first, then the client, then a full redraw: tmux repaints as soon as the PTY
        // changes size, and a repaint that lands before the view has resized is lost.
        attachSize = size
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard self.attach === attach, self.attachSize == size else { return }
            attach.size = (size.cols, size.rows)
            try? await Task.sleep(for: .milliseconds(120))
            await tmux?.redraw(clientPID: attach.pid)
        }
    }

    func release() {
        attachController?.release()
        attach = nil
        attachSize = nil
        focusedSeatID = nil
        typing = false
    }
}

struct GridSize: Equatable {
    var cols: Int
    var rows: Int
}

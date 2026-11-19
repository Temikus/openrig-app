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
    var typing = false {
        didSet { if typing { pausedForPrompt = nil } }
    }
    /// Type mode stopped because the focused seat raised a permission prompt: Enter would have answered it.
    private(set) var pausedForPrompt: Seat.ID?
    /// How far the focused client is panned down from the pane's top, for the header's "rows above".
    private(set) var panned = 0
    /// Seats in display order, for ⌘] and ⌘[. Written by the grid as it lays out; not observed.
    @ObservationIgnored var order: [Seat.ID] = []
    /// The grid's last arrangement, frozen when focus begins. Written by the grid; not observed.
    @ObservationIgnored var layout: FrozenOrder?

    @ObservationIgnored private var attachController: FocusedAttach?
    /// The focused client's tty, looked up once per attach for panning.
    @ObservationIgnored private var attachTTY: (pid: Int32, tty: String)?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?

    init(tmux: Tmux?) {
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
        if focusedSeatID != seat.id {
            typing = false
            pausedForPrompt = nil
            panned = 0
        }
        let snap = snapshot(seat)
        // The client gets the pane's size plus the status bar, so the pane shows whole.
        let cols = snap?.cols ?? 80
        let rows = (snap?.rows ?? 24) + (snap?.statusRows ?? 0)
        attach = controller.focus(session: session, cols: cols, rows: rows)
        attachSize = attach.map { GridSize(cols: $0.size.cols, rows: $0.size.rows) }
        focusedSeatID = seat.id
    }

    /// Resizes the focused client, to the pane's size when the pane changes. Smaller than the pane, the client
    /// would show only its top rows, not the input at the bottom.
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

    /// Pans the focused client down `rows` from the pane's top (see `PaneSnapshot.panOffset`).
    func pan(_ rows: Int) {
        guard let attach, let tmux else { return }
        panned = rows
        Task { @MainActor in
            // After any resize in flight, which resets what tmux shows.
            try? await Task.sleep(for: .milliseconds(250))
            guard self.attach === attach, self.panned == rows else { return }
            if attachTTY?.pid != attach.pid, let tty = await tmux.clientTTY(pid: attach.pid) {
                attachTTY = (attach.pid, tty)
            }
            guard let tty = attachTTY?.tty else { return }
            await tmux.pan(tty: tty, down: rows)
        }
    }

    /// Asks tmux to repaint the focused client, after its view was rebuilt or reset.
    func repaint() {
        guard let attach, let tmux else { return }
        Task { await tmux.redraw(clientPID: attach.pid) }
    }

    /// Stops Type mode because `seat` is asking for permission, so no key answers it.
    func pauseForPrompt(on seat: Seat.ID) {
        guard typing, focusedSeatID == seat else { return }
        typing = false
        pausedForPrompt = seat
    }

    func release() {
        attachController?.release()
        attach = nil
        attachSize = nil
        focusedSeatID = nil
        typing = false
        pausedForPrompt = nil
        panned = 0
    }
}

struct GridSize: Equatable {
    var cols: Int
    var rows: Int
}

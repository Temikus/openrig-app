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
    /// Keys go straight to tmux only in Type mode. It resets on Esc and on focus moves.
    var typing = false

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
        focusedSeatID = seat.id
    }

    func release() {
        attachController?.release()
        attach = nil
        focusedSeatID = nil
        typing = false
    }
}

import RigClient
import RigDomain
import RigModel
import SwiftUI

/// What a down seat means and how to bring it back, on the seat itself. Both commands touch only this seat:
/// `rig launch` leaves running seats alone, and `rig seat launch --fresh` leaves sibling seats attached.
struct DownSeatNotice: View {
    let seat: Seat
    let presence: SeatPresence
    @Environment(RigStore.self) private var rig
    @Environment(AppStore.self) private var store
    @Environment(ActionStore.self) private var actions
    @State private var confirmingFresh = false

    private var key: String { "seat-launch:\(seat.id)" }
    private var resume: RigAction { .launchSeat(rig: rig.rigName, logicalId: seat.logicalId) }
    private var fresh: RigAction? {
        seat.sessionName.map { .freshSeat(session: $0, reason: "OpenRig.app: start \(seat.displayName) fresh") }
    }
    private var rigStopped: Bool { store.selectedRig.map(isStopped) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.callout)
            if !seat.currentQItems.isEmpty {
                Text("Its in-progress work is stalled until it's back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if rigStopped {
                Text("The whole rig is stopped. Start Rig brings every seat back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    // The usual fix, so it leads; Start Fresh is the fallback (design 5A).
                    Button("Resume Seat") {
                        Task { await actions.perform(resume, key: key, success: "\(seat.displayName) launched") }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(resume.userCommand)
                    Button("Start Fresh…") { confirmingFresh = true }
                        .help(fresh?.userCommand ?? "This seat has no session name")
                        .disabled(fresh == nil)
                }
                .disabled(actions.isRunning(key) || actions.offline)
                ActionStatusLine(key: key)
            }
        }
        .confirmationDialog(
            "Start \(seat.displayName) with a blank conversation?", isPresented: $confirmingFresh,
            titleVisibility: .visible
        ) {
            Button("Start Fresh") {
                guard let fresh else { return }
                Task { await actions.perform(fresh, key: key, success: "\(seat.displayName) started fresh") }
            }
        } message: {
            Text("Its current conversation isn't resumed. Use this when Resume Seat can't bring it back.")
        }
    }

    private var headline: String {
        switch presence {
        case .lost: "The seat's tmux session is gone without a stop. The agent may have crashed."
        case .failed: "The seat failed to start."
        default: "The seat's session exited."
        }
    }
}

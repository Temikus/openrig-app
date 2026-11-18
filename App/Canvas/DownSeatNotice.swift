import AppKit
import RigDomain
import RigModel
import SwiftUI

/// What a down seat means and how to bring it back. The app doesn't restore seats itself:
/// `rig up --existing` restores the whole rig, so the user previews it first.
struct DownSeatNotice: View {
    let seat: Seat
    let presence: SeatPresence
    @Environment(RigStore.self) private var rig

    private var command: String { "rig up \(rig.rigName) --existing --plan" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline).font(.callout)
            if !seat.currentQItems.isEmpty {
                Text("Its in-progress work is stalled until it's back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
                .help("Previews a restore of the rig's seats; drop --plan to run it")
            }
            .padding(6)
            .background(.background, in: .rect(cornerRadius: 6))
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

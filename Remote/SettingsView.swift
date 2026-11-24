import RigClient
import SwiftUI

/// The paired Mac and Unpair.
struct SettingsView: View {
    @Environment(RemoteSession.self) private var model
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent(model.macName) { StatusLabel() }
                    if let address = model.address {
                        LabeledContent("Address") { Text(address).monospaced() }
                    }
                    if let answeringAs = model.answeringAs {
                        LabeledContent("Answering as", value: answeringAs)
                    }
                    if let pairedAt = model.pairing?.pairedAt {
                        LabeledContent("Paired", value: pairedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Section {
                    Button("Unpair this phone", role: .destructive) { confirmingUnpair = true }
                } footer: {
                    Text(
                        "This only forgets the Mac on this phone. To cut the phone off, unpair it in OpenRig on the Mac, under Settings › Phone."
                    )
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Unpair this phone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
            } message: {
                Text("To pair again, scan the code on your Mac.")
            }
        }
    }
}

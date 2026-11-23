import SwiftUI

@main
struct OpenRigRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            NotPairedView()
        }
    }
}

/// The whole app until pairing lands: nothing is stored yet, so the phone is never paired.
struct NotPairedView: View {
    var body: some View {
        ContentUnavailableView(
            "Not paired", systemImage: "iphone.slash",
            description: Text("Pair this iPhone from OpenRig on your Mac."))
    }
}

#Preview {
    NotPairedView()
}

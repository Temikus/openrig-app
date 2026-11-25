import RigClient
import SwiftUI

extension View {
    /// Asks before `RemoteSession.unpair()`, which can't be undone from the phone: it forgets the pairing and any
    /// answers not yet confirmed. An alert, not a confirmation dialog: iOS 26 draws a dialog without its Cancel.
    func unpairConfirmation(isPresented: Binding<Bool>, _ kind: UnpairWording.Kind) -> some View {
        modifier(UnpairConfirmation(isPresented: isPresented, kind: kind))
    }
}

private struct UnpairConfirmation: ViewModifier {
    @Environment(RemoteSession.self) private var model
    @Binding var isPresented: Bool
    var kind: UnpairWording.Kind

    func body(content: Content) -> some View {
        let words = UnpairWording(kind, mac: model.macName, unsent: model.unsentAnswers)
        return content.alert(words.title, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(words.confirm, role: .destructive) { model.unpair() }
        } message: {
            Text(words.message)
        }
    }
}

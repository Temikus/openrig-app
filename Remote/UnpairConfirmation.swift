import RigClient
import SwiftUI

extension View {
    /// Asks before `RemoteSession.unpair()`, which can't be undone from the phone: it forgets the pairing and any
    /// answers not yet confirmed. An alert, not a confirmation dialog: iOS 26 draws a dialog without its Cancel.
    func unpairConfirmation(isPresented: Binding<Bool>, title: String, confirm: String) -> some View {
        modifier(UnpairConfirmation(isPresented: isPresented, title: title, confirm: confirm))
    }
}

private struct UnpairConfirmation: ViewModifier {
    @Environment(RemoteSession.self) private var model
    @Binding var isPresented: Bool
    var title: String
    var confirm: String

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirm, role: .destructive) { model.unpair() }
        } message: {
            Text(message)
        }
    }

    var message: String {
        var parts = ["You'll need a new code from the Mac."]
        switch model.unsentAnswers {
        case 0: break
        case 1: parts.append("1 answer this phone hasn't confirmed yet will be dropped.")
        case let n: parts.append("\(n) answers this phone hasn't confirmed yet will be dropped.")
        }
        parts.append("\(model.macName) still lists this phone until you unpair it there, under Settings › Phone.")
        return parts.joined(separator: " ")
    }
}

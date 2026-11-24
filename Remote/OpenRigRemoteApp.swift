import RigClient
import RigModel
import SwiftUI

@main
struct OpenRigRemoteApp: App {
    @State private var model = RemoteSession.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // A pairing link opened from the camera, Messages or a web page. It waits for a confirmation.
                .onOpenURL { model.receive(openedLink: $0.absoluteString) }
                #if DEBUG
                    // Here, not in the model's init: SwiftUI may build an App's @State value more than once.
                    .task {
                        if let link = DebugHooks.pairLink { model.pair(link: link) }
                        if let link = DebugHooks.openedLink { model.receive(openedLink: link) }
                        DebugHooks.seedUnsent(for: model.pairing?.code.credentialID)
                    }
                #endif
                // While the app is open: every five seconds, and on each event from the Mac. Cancelled in the
                // background.
                .task(id: scenePhase == .active) {
                    if scenePhase == .active { await model.keepFresh() }
                }
        }
    }
}

enum RemoteTab: Hashable {
    case needs, rigs, settings
}

struct RootView: View {
    @Environment(RemoteSession.self) private var model
    @State private var tab = RemoteTab.needs

    var body: some View {
        content
            // An alert, not a confirmation dialog: iOS 26 draws a dialog without its Cancel button, which would leave
            // accepting a stranger's link as the only visible choice.
            .alert(
                "Pair with \(model.pendingCode?.name ?? "this Mac")?", isPresented: pendingBinding,
                presenting: model.pendingCode
            ) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Pair") { model.confirmPending() }
            } message: { code in
                Text(pendingMessage(code))
            }
            .alert("OpenRig", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.pairingError ?? "")
            }
    }

    var pendingBinding: Binding<Bool> {
        Binding(get: { model.pendingCode != nil }, set: { if !$0 { model.pendingCode = nil } })
    }

    /// The pairing flow shows its own errors. Once paired, an opened link's error or a failed Unpair needs an alert.
    var errorBinding: Binding<Bool> {
        Binding(
            get: { model.pairing != nil && model.pairingError != nil },
            set: { if !$0 { model.pairingError = nil } })
    }

    func pendingMessage(_ code: PairingCode) -> String {
        let address = RemoteEndpoint.all(in: code).first?.description ?? ""
        let replaces = model.pairing.map { _ in " This replaces \(model.macName)." } ?? ""
        // The warning first: at large text sizes the alert cuts the end of its message.
        return
            "Pair only if this link came from your own Mac.\(replaces) It asks this phone to answer as \(code.actor) through \(address)."
    }

    @ViewBuilder var content: some View {
        if model.pairing == nil {
            PairingFlow()
        } else {
            TabView(selection: $tab) {
                Tab("Needs you", systemImage: "tray", value: .needs) { NeedsYouView() }
                    .badge(model.needsYouList?.count ?? 0)
                Tab("Rigs", systemImage: "point.3.connected.trianglepath.dotted", value: .rigs) { RigsView() }
                Tab("Settings", systemImage: "gear", value: .settings) { SettingsView() }
            }
            #if DEBUG
                .onAppear {
                    switch DebugHooks.screen {
                    case "settings": tab = .settings
                    case "rigs": tab = .rigs
                    default: break
                    }
                }
            #endif
        }
    }
}

/// The dot and words for where the phone stands. The words carry the state; the colour only repeats it.
struct StatusLabel: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        Label {
            Text(Self.words(for: model.status))
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Self.colour(for: model.status))
        }
        .labelStyle(.titleAndIcon)
    }

    static func words(for status: RemoteStatus?) -> String {
        switch status {
        case nil: "Connecting…"
        case .connected: "Connected"
        case .unreachable: "Can't reach"
        case .localNetworkDenied: "Local Network off"
        case .unpaired: "Unpaired"
        case .unsupportedDaemon: "Can't talk to it"
        case .noSafeAddress: "Wi-Fi not ready"
        }
    }

    static func colour(for status: RemoteStatus?) -> Color {
        switch status {
        case nil: .secondary
        case .connected: .statusGood
        default: .statusBad
        }
    }
}

extension Color {
    /// Deeper in light appearance so the dot keeps its contrast on white (mock-designer's measurements).
    static let statusGood = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(rgb: 0x18914E) })
    static let statusBad = Color(UIColor { $0.userInterfaceStyle == .dark ? .systemRed : UIColor(rgb: 0xC24236) })
    /// "Needs you", as the Mac's `attention`: a soft coral in dark appearance, a deeper red in light for contrast on
    /// white. The prompt's command block is this at 8%, as on the Mac.
    static let attention = Color(
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xED8775) : UIColor(rgb: 0xC74033) })
    /// Behind white text: deep enough for 4.5:1 in both appearances, as the Mac's `attentionFill`.
    static let attentionFill = Color(UIColor(rgb: 0xC24236))
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

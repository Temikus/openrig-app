import RigClient
import SwiftUI

@main
struct OpenRigRemoteApp: App {
    @State private var model = RemoteModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // A pairing link opened from the camera, Messages or `simctl openurl`.
                .onOpenURL { model.pair(link: $0.absoluteString) }
                #if DEBUG
                    // Here, not in the model's init: SwiftUI may build an App's @State value more than once.
                    .task { if let link = DebugHooks.pairLink { model.pair(link: link) } }
                #endif
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}

/// A Rigs tab adds a case here and a `Tab` below.
enum RemoteTab: Hashable {
    case needs, settings
}

struct RootView: View {
    @Environment(RemoteModel.self) private var model
    @State private var tab = RemoteTab.needs

    var body: some View {
        if model.pairing == nil {
            PairingFlow()
        } else {
            TabView(selection: $tab) {
                Tab("Needs you", systemImage: "tray", value: .needs) { NeedsYouView() }
                    .badge(model.needs?.requests.count ?? 0)
                Tab("Settings", systemImage: "gear", value: .settings) { SettingsView() }
            }
            #if DEBUG
                .onAppear { if DebugHooks.screen == "settings" { tab = .settings } }
            #endif
        }
    }
}

/// The dot and words for where the phone stands. The words carry the state; the colour only repeats it.
struct StatusLabel: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Label {
            Text(words)
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(colour)
        }
        .labelStyle(.titleAndIcon)
    }

    var words: String {
        switch model.status {
        case nil: "Connecting…"
        case .connected: "Connected"
        case .unreachable: "Can't reach"
        case .localNetworkDenied: "Local Network off"
        case .unpaired: "Unpaired"
        case .unsupportedDaemon: "Can't talk to it"
        }
    }

    var colour: Color {
        switch model.status {
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
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

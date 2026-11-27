import RigClient
import SwiftUI

@main
struct OpenRigApp: App {
    static let mainWindow = "main"
    /// `just install` builds the canary with a `.canary` bundle id. Its mark has a hollow centre seat.
    static let menuBarMark =
        Bundle.main.bundleIdentifier?.hasSuffix(".canary") == true ? "MenuBarMarkCanary" : "MenuBarMark"
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OpenRig"
    @State private var store: AppStore

    init() {
        RequestLog.installAtLaunch()
        let store = AppStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("OpenRig", id: Self.mainWindow) {
            ContentView()
                .environment(store)
                // Minimum width is ContentView's: it grows while the inspector is open.
                .frame(minHeight: 520)
        }
        .defaultSize(width: 1440, height: 900)
        // The window's minimum follows the content's, which grows while the inspector is open (ContentView).
        .windowResizability(.contentMinSize)
        // Saved state from before the window had an id restores nothing; open one anyway.
        .defaultLaunchBehavior(.presented)
        .commands { OpenRigCommands(store: store) }

        Window("Needs You", id: NeedsYouWindow.id) {
            NeedsYouWindow()
                .environment(store)
        }
        .defaultSize(width: 960, height: 640)
        // OPENRIG_DEBUG_NEEDS_YOU=queue[/<qitem id>] opens it at launch, behind other windows as the main one does.
        // An openWindow call at launch brought the app to the front.
        .defaultLaunchBehavior(NeedsYouWindow.opensAtLaunch ? .presented : .automatic)

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra(isInserted: Bindable(store.settings).menuBarItem) {
            MenuBarNeedsYou()
                .environment(store)
        } label: {
            let waiting = store.waitingEverywhere
            // Not a Label: in a MenuBarExtra it draws only the image, so the count would never show.
            HStack {
                Image(Self.menuBarMark)
                if waiting.urgent > 0 { Text("\(waiting.urgent)") }
            }
            .accessibilityLabel(waiting.menuBarLabel(appName: Self.appName))
        }
        .menuBarExtraStyle(.window)
    }
}

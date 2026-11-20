import SwiftUI

@main
struct OpenRigApp: App {
    static let mainWindow = "main"
    @State private var store: AppStore

    init() {
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

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra(isInserted: Bindable(store.settings).menuBarItem) {
            MenuBarNeedsYou()
                .environment(store)
        } label: {
            let urgent = store.waitingEverywhere.urgent
            Label(urgent > 0 ? "\(urgent)" : "OpenRig", systemImage: urgent > 0 ? "bell.badge.fill" : "bell")
        }
        .menuBarExtraStyle(.window)
    }
}

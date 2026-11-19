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
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 900)
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

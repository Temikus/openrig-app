import SwiftUI

@main
struct OpenRigApp: App {
    @State private var store: AppStore

    init() {
        let store = AppStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup("OpenRig") {
            ContentView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(before: .toolbar) {
                ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.title) { store.viewMode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Refresh") { Task { await store.refreshNow() } }
                    .keyboardShortcut("r")
                Button("Search Queue") {
                    store.viewMode = .queue
                    store.wantsSearch = true
                }
                .keyboardShortcut("f")
                // With no rig there's no board to focus, and the request would linger for a later visit.
                .disabled(store.rig == nil)
                Divider()
            }
        }

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

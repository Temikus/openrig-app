import SwiftUI

@main
struct OpenRigApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("OpenRig") {
            ContentView()
                .environment(store)
                .task { await store.run() }
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refreshNow() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

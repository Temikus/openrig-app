import SwiftUI

/// The Needs-you list in the menu bar (Settings › General › Show in the menu bar). Opening a row brings the main
/// window forward, reopening it if it was closed.
struct MenuBarNeedsYou: View {
    @Environment(AppStore.self) private var app

    var body: some View {
        Group {
            if let rig = app.rig {
                NeedsYouList(entries: rig.needsYou, elsewhere: app.elsewhere, attention: app.attentionElsewhere) {
                    app.showMainWindow()
                }
                .environment(rig)
            } else {
                NeedsYouList(entries: [], elsewhere: app.elsewhere, attention: app.attentionElsewhere) {
                    app.showMainWindow()
                }
            }
        }
        .environment(app.selection)
        .environment(app.actions)
    }
}

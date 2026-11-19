import SwiftUI

/// The Settings window (⌘,): one grouped form per tab, as drawn on the Paper page "Settings window".
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Connection", systemImage: "point.3.connected.trianglepath.dotted") { ConnectionSettings() }
            Tab("Notifications", systemImage: "bell") { NotificationSettings() }
            Tab("Terminals", systemImage: "apple.terminal") { TerminalSettings() }
        }
        .frame(width: 640)
        .scenePadding(.bottom)
    }
}

/// A form row's label with a caption under it, as Form renders two texts in a label.
struct RowLabel: View {
    let title: String
    let caption: String?

    init(_ title: String, _ caption: String? = nil) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        Text(title)
        if let caption { Text(caption) }
    }
}

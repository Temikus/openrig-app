import SwiftUI

/// The Settings window (⌘,): one grouped form per tab, as drawn on the Paper page "Settings window".
struct SettingsView: View {
    enum Pane: String { case general, connection, notifications, terminals, phone }

    /// Reopens on the last tab, as Mac Settings windows do.
    @AppStorage("settingsPane") private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Connection", systemImage: "point.3.connected.trianglepath.dotted", value: .connection) {
                ConnectionSettings()
            }
            Tab("Notifications", systemImage: "bell", value: .notifications) { NotificationSettings() }
            Tab("Terminals", systemImage: "apple.terminal", value: .terminals) { TerminalSettings() }
            Tab("Phone", systemImage: "iphone", value: .phone) { PhoneSettings() }
        }
        .frame(width: 640)
        #if DEBUG
            // OPENRIG_DEBUG_SETTINGS=<pane> opens Settings on that tab at launch, for screenshots without a click.
            .onAppear {
                if let debug = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SETTINGS"].flatMap(Pane.init) {
                    pane = debug
                }
            }
        #endif
    }
}

extension View {
    /// A Settings tab's form at its natural height, so the window fits each tab instead of scrolling.
    func settingsForm() -> some View {
        formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
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

import AppKit
import RigDomain
import SwiftUI
import UserNotifications

struct NotificationSettings: View {
    @Environment(AppStore.self) private var store
    @State private var permission: UNAuthorizationStatus?

    static let sounds = ["", "Glass", "Ping", "Pop", "Submarine", "Tink"]

    /// The Settings window's tab (SettingsView keeps it in this key), for the link to General.
    @AppStorage("settingsPane") private var pane = SettingsView.Pane.notifications.rawValue

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section { permissionRow }
            Section("Show a banner when") {
                Toggle(isOn: kind(.permission)) {
                    RowLabel("A seat asks for permission", "Clicking it opens OpenRig at the prompt.")
                }
                comingLater(
                    "Offer Allow once in the banner", "Needs a check that the prompt hasn't changed since the banner.")
                Toggle(isOn: kind(.ask)) {
                    RowLabel("An agent asks you something", "Clicking it opens the row in the inspector.")
                }
                Toggle("An agent replies to you", isOn: kind(.reply))
                Toggle("A seat goes down", isOn: kind(.seatDown))
                Toggle(isOn: kind(.daemonDown)) {
                    RowLabel("The daemon stops answering", "After 30 s, so a restart doesn't ping you.")
                }
            }
            Section("Delivery") {
                Toggle(isOn: $settings.bannersOnlyInBackground) {
                    Text("Only when the window is closed or behind")
                    HStack(spacing: 4) {
                        Text("Needs OpenRig running:")
                        // To the setting itself, rather than describing where it is.
                        Button("Open at login") { pane = SettingsView.Pane.general.rawValue }
                            .buttonStyle(.link)
                    }
                }
                Picker("From", selection: $settings.bannerScope) {
                    ForEach(AppSettings.BannerScope.allCases) { Text($0.title).tag($0) }
                }
                comingLater("Read prompts on every rig", "Other rigs' prompts arrive as a count, without the command.")
                Picker("Sound for permission prompts", selection: $settings.promptSound) {
                    ForEach(Self.sounds, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) }
                }
                .onChange(of: settings.promptSound) { NSSound(named: settings.promptSound)?.play() }
            }
        }
        .settingsForm()
        .task { await refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermission() }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch permission {
        case .notDetermined?:
            LabeledContent {
                Button("Allow…") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
                            .alert, .sound,
                        ])
                        await refreshPermission()
                    }
                }
            } label: {
                RowLabel("OpenRig hasn't asked yet", "macOS shows its prompt once.")
            }
        case .denied?:
            LabeledContent {
                Button("Open System Settings…", action: openSystemSettings)
            } label: {
                Text("Notifications are off for OpenRig")
                Text("None of the banners below will show.").foregroundStyle(Color.attention)
            }
        case nil:
            EmptyView()
        default:
            LabeledContent {
                Button("Open System Settings…", action: openSystemSettings)
            } label: {
                RowLabel("Allowed in System Settings", "Banner style and Focus modes are set there.")
            }
        }
    }

    private func kind(_ kind: NoticeKind) -> Binding<Bool> {
        Binding(get: { store.settings.bannerKinds.contains(kind) }, set: { store.settings.setBanner(kind, $0) })
    }

    private func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.openrig.OpenRig"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NotificationSettings {
    /// A planned option: a label, not a switch that looks live but does nothing.
    fileprivate func comingLater(_ title: String, _ caption: String) -> some View {
        LabeledContent {
            Text("Coming later").foregroundStyle(.secondary)
        } label: {
            RowLabel(title, caption)
        }
    }
}

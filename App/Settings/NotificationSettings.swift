import AppKit
import RigDomain
import SwiftUI
import UserNotifications

struct NotificationSettings: View {
    @Environment(AppStore.self) private var store
    @State private var permission: UNAuthorizationStatus?

    static let sounds = ["", "Glass", "Ping", "Pop", "Submarine", "Tink"]

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section { permissionRow }
            Section("Show a banner when") {
                Toggle(isOn: kind(.permission)) {
                    RowLabel("A seat asks for permission", "Clicking it opens OpenRig at the prompt.")
                }
                Toggle(isOn: .constant(false)) {
                    RowLabel(
                        "Offer Allow once in the banner",
                        "Coming later. It needs a check that the prompt hasn't changed since the banner.")
                }
                .disabled(true)
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
                    RowLabel(
                        "Only when the window is closed or behind",
                        "Needs OpenRig running. See General › Open at login.")
                }
                Picker("From", selection: $settings.bannerScope) {
                    ForEach(AppSettings.BannerScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: .constant(false)) {
                    RowLabel(
                        "Read prompts on every rig",
                        "Coming later. Other rigs' prompts arrive as a count, without the command.")
                }
                .disabled(true)
                Picker("Sound for permission prompts", selection: $settings.promptSound) {
                    ForEach(Self.sounds, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) }
                }
                .onChange(of: settings.promptSound) { NSSound(named: settings.promptSound)?.play() }
            }
        }
        .formStyle(.grouped)
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

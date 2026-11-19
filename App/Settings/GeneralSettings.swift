import AppKit
import RigModel
import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    /// A person picked in Act as who isn't the gateway default: confirmed before the app acts as them.
    @State private var pendingActAs: String?
    @State private var loginError: String?
    /// SMAppService isn't observable, so the toggle keeps its own copy.
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    private let registerCommand = "rig gateway human add <id> --default"

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("You") { actAs }
            Section("On launch") {
                Toggle(isOn: openAtLogin) {
                    RowLabel(
                        "Open at login", loginError ?? "Keeps banners and the badge working before you open a window.")
                }
                Picker("Open to", selection: $settings.openTo) {
                    ForEach(AppSettings.OpenTo.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.reopenLastRig) {
                    RowLabel("Reopen the last rig", "Off: start on the first rig in the list.")
                }
            }
            Section("Badge") {
                Toggle(isOn: $settings.dockBadge) {
                    RowLabel("Show the count on the Dock icon", "Asks and prompts on every rig. FYIs don't count.")
                }
                Toggle(isOn: $settings.menuBarItem) {
                    RowLabel("Show in the menu bar", "Needs you, one click away with the window closed.")
                }
            }
            Section("Display") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.appearance) { NSApp.appearance = settings.appearance.nsAppearance }
        .confirmationDialog(
            "Act as \(pendingActAs ?? "") instead?", isPresented: pendingBinding, presenting: pendingActAs
        ) { address in
            Button("Switch") { actAs(address) }
            Button("Keep \(store.me)", role: .cancel) {}
        } message: { address in
            Text(
                Human.isYou(address)
                    ? "Agents' replies to \(address) can't wake you, and the daemon pings the sender about each one."
                    : "Writes and replies will name \(address), not the gateway's default person.")
        }
    }

    @ViewBuilder private var actAs: some View {
        if store.people.isEmpty {
            LabeledContent {
                Text(store.me)
            } label: {
                RowLabel("Act as", "Nobody is registered with the gateway, so agents' replies can't wake you.")
            }
            LabeledContent {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(registerCommand, forType: .string)
                }
            } label: {
                Text("Register yourself")
                Text(registerCommand).monospaced()
            }
        } else {
            Picker(selection: actAsBinding) {
                ForEach(store.people + [Human.session], id: \.self) { Text($0).tag($0) }
            } label: {
                RowLabel("Act as", store.me == store.gateway?.defaultAddress ? "The gateway's default person." : nil)
            }
        }
    }

    private var actAsBinding: Binding<String> {
        Binding(
            get: { store.me },
            set: { address in
                if address == store.gateway?.defaultAddress { actAs(address) } else { pendingActAs = address }
            })
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pendingActAs != nil }, set: { if !$0 { pendingActAs = nil } })
    }

    private func actAs(_ address: String) {
        store.settings.actAs = address == store.gateway?.defaultAddress ? nil : address
        store.applyIdentity()
    }

    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { loginOn },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                loginOn = SMAppService.mainApp.status == .enabled
            })
    }
}

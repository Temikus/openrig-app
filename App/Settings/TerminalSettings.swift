import SwiftUI

struct TerminalSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Text") {
                Stepper(value: $settings.smallestTileText, in: AppSettings.smallestTileTextRange, step: 0.5) {
                    LabeledContent {
                        Text("\(settings.smallestTileText, format: .number) pt").monospacedDigit()
                    } label: {
                        RowLabel(
                            "Smallest tile text",
                            "Tiles shrink text to fit the pane. Below this, wide panes clip on the right.")
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.typeOnFocus) {
                    RowLabel(
                        "Start typing when I focus a tile",
                        "Off: ⌘T or a second click starts typing. Never on a tile showing a prompt.")
                }
                Picker(selection: $settings.escGoesToPane) {
                    Text("Stops typing").tag(false)
                    Text("Goes to the pane").tag(true)
                } label: {
                    RowLabel("Esc while typing", "Sent to the pane, Esc interrupts the agent and only ⌘T stops typing.")
                }
                .pickerStyle(.segmented)
                Toggle("Use Option as Meta", isOn: $settings.optionAsMeta)
            } header: {
                Text("Typing into a pane")
            } footer: {
                Text(
                    "OpenRig has no shortcut for Allow once. While typing, keys go to the pane, so Enter on a prompt answers it."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

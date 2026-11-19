import AppKit
import RigClient
import RigModel
import SwiftUI

struct ConnectionSettings: View {
    @Environment(AppStore.self) private var store
    @State private var custom = false
    @State private var customText = ""
    @State private var test: TestState = .idle
    @State private var tokenText = ""

    enum TestState: Equatable {
        case idle, testing
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Daemon") {
                status
                address
                token
            }
            Section {
                ToolRow(tool: .rig)
                ToolRow(tool: .tmux)
                ToolRow(tool: .node)
            } header: {
                Text("Command-line tools")
            } footer: {
                Text(
                    "Apps opened from the Dock don't get your shell's PATH, so node from nvm, asdf or mise is often "
                        + "missed. In the file picker, ⇧⌘G reaches hidden folders like /opt/homebrew/bin."
                )
                .foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .onAppear {
            custom = store.settings.customAddress != nil
            customText = store.settings.customAddress?.absoluteString ?? ""
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch store.daemon {
        case .connecting:
            LabeledContent {
                EmptyView()
            } label: {
                RowLabel(
                    "Connecting…", "Trying \(store.endpoint.baseURL.host() ?? store.endpoint.baseURL.absoluteString)")
            }
        case .running(let health):
            LabeledContent {
                Button("Reconnect") { Task { await store.refreshNow() } }
            } label: {
                Label {
                    RowLabel(connectedTitle(health), connectedCaption(health))
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(.green).imageScale(.small)
                }
            }
        case .unreachable(let reason, let since):
            LabeledContent {
                Button("Start daemon") { Task { await store.startDaemon() } }
            } label: {
                Label {
                    Text("Not answering")
                    Text(
                        "\(reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) since \(since.formatted(date: .omitted, time: .shortened))"
                    )
                    .foregroundStyle(Color.attention)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Color.attention).imageScale(.small)
                }
            }
        }
    }

    private func connectedTitle(_ health: DaemonHealth) -> String {
        if case .untested(let version) = health.compatibility { return "Connected to rig \(version)" }
        return "Connected"
    }

    private func connectedCaption(_ health: DaemonHealth) -> String {
        if case .untested = health.compatibility {
            let tested = DaemonHealth.testedMinor
            return "Untested. Built against \(tested.major).\(tested.minor).x, so some views may be wrong."
        }
        let stream = store.isLive ? "event stream live" : "polling"
        let rigs = store.rigs.count == 1 ? "1 rig" : "\(store.rigs.count) rigs"
        return ["rig \(health.semver ?? "?")", stream, rigs].joined(separator: " · ")
    }

    // MARK: Address

    @ViewBuilder private var address: some View {
        Picker(selection: customBinding) {
            Text("Find automatically").tag(false)
            Text("Custom").tag(true)
        } label: {
            RowLabel("Address", custom ? nil : foundCaption)
        }
        if custom {
            HStack {
                TextField("Address", text: $customText, prompt: Text("http://127.0.0.1:7433"))
                    .labelsHidden()
                    .monospaced()
                    .onSubmit { Task { await testAndUse() } }
                Button("Test") { Task { await testAndUse() } }
                    .disabled(test == .testing || DaemonLocator.normalized(customText) == nil)
            }
            if case .failed(let message) = test {
                Text("\(message). The old address stays in use until a test passes.")
                    .font(.caption).foregroundStyle(Color.attention)
            }
            if let host = DaemonLocator.normalized(customText)?.host(), !isLoopback(host) {
                Text("Not on this Mac: terminals and permission prompts need local tmux, so they'll be empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var foundCaption: String {
        let host = store.endpoint.baseURL.host().map { "\($0):\(store.endpoint.baseURL.port ?? 80)" } ?? ""
        switch store.endpoint.source {
        case .stateFile: return "\(host) from ~/.openrig/daemon.json"
        case .environment: return "\(host) from OPENRIG_URL"
        case .fallback: return "\(host), the default"
        case .custom: return host
        }
    }

    private var customBinding: Binding<Bool> {
        Binding(
            get: { custom },
            set: { on in
                custom = on
                test = .idle
                if !on, store.settings.customAddress != nil {
                    store.settings.customAddress = nil
                    store.applyConnectionSettings()
                }
            })
    }

    /// Switches to the typed address only once its daemon answers.
    private func testAndUse() async {
        guard let url = DaemonLocator.normalized(customText) else { return }
        test = .testing
        do {
            _ = try await DaemonHTTP(baseURL: url, timeout: 5, bearer: store.token).health()
            test = .idle
            store.settings.customAddress = url
            store.applyConnectionSettings()
        } catch {
            test = .failed(error.userMessage)
        }
    }

    private func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: Token

    @ViewBuilder private var token: some View {
        if store.token != nil {
            LabeledContent {
                Button("Remove") {
                    OperatorToken.save("")
                    store.applyConnectionSettings()
                }
            } label: {
                RowLabel("Operator token", "Saved in the Keychain. Sent with answers and rig commands.")
            }
        } else {
            LabeledContent {
                SecureField("Token", text: $tokenText, prompt: Text("Only if the daemon has a bearer"))
                    .labelsHidden()
                    .frame(width: 220)
                    .onSubmit {
                        guard OperatorToken.save(tokenText) else { return }
                        tokenText = ""
                        store.applyConnectionSettings()
                    }
            } label: {
                RowLabel("Operator token", "Kept in the Keychain. Also passed to rig commands.")
            }
        }
    }
}

/// One command-line tool: where it is, its version, and a way to pick another.
private struct ToolRow: View {
    enum Tool: String {
        case rig, tmux, node

        var searchPaths: [String] {
            switch self {
            case .rig: RigCLI.searchPaths
            case .tmux: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            case .node: ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            }
        }

        /// What stops working without it.
        var missing: String {
            switch self {
            case .rig: "Not found. Actions can't run; reading still works."
            case .tmux: "Not found. Terminals and permission prompts won't show."
            case .node: "Not found. rig can't start, so actions can't run; reading still works."
            }
        }
    }

    let tool: Tool
    @Environment(AppStore.self) private var store
    @State private var version: String?

    private var override: URL? {
        switch tool {
        case .rig: store.settings.rigPath
        case .tmux: store.settings.tmuxPath
        case .node: store.settings.nodePath
        }
    }

    private var location: ToolLocation? { ToolLocator.resolve(override: override, searchPaths: tool.searchPaths) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let version { Text(version).monospaced().foregroundStyle(.secondary) }
                if override != nil { Button("Use automatic") { pick(nil) } }
                Button("Choose…", action: choose)
            }
        } label: {
            Text(tool.rawValue)
            if let location {
                Text(location.url.path(percentEncoded: false) + (location.chosen ? " · chosen by you" : ""))
                    .monospaced()
            } else {
                Text(override == nil ? tool.missing : "The chosen file is missing. " + tool.missing)
                    .foregroundStyle(Color.attention)
            }
        }
        .task(id: location?.url) {
            version = nil
            if let url = location?.url {
                version = await ToolLocator.version(of: url, flag: tool == .tmux ? "-V" : "--version")
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
        panel.message = "Choose the \(tool.rawValue) executable"
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }

    private func pick(_ url: URL?) {
        switch tool {
        case .rig: store.settings.rigPath = url
        case .tmux: store.settings.tmuxPath = url
        case .node: store.settings.nodePath = url
        }
        store.applyConnectionSettings()
    }
}

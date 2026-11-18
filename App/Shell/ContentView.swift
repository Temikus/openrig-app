import RigModel
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var showsInspector = true
    /// Remembered per view: Terminals starts without the inspector, since its tiles carry each seat's state.
    @State private var inspectorByMode: [ViewMode: Bool] = [.terminals: false]
    @State private var showsQueueTask = false
    /// Too narrow for the full toolbar: Needs you shrinks to a bell and a count so it never overflows.
    @State private var narrow = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            RigSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            RigDetail()
                .inspector(isPresented: $showsInspector) {
                    InspectorPanel()
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
        }
        .environment(store.selection)
        .environment(store.actions)
        .onChange(of: store.viewMode, initial: true) { old, new in
            if old != new { inspectorByMode[old] = showsInspector }
            showsInspector = inspectorByMode[new] ?? true
        }
        .onGeometryChange(for: Bool.self) {
            $0.size.width < 1100
        } action: {
            narrow = $0
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label {
                            // The shortcut, as in the design; dimmed where the control keeps text styling.
                            Text(mode.title) + Text("  \(mode.shortcutHint)").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: mode.systemImage)
                        }
                        .labelStyle(.adaptive(iconOnly: narrow))
                        .help("\(mode.title) (\(mode.shortcutHint))")
                        .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // The toolbar keeps an item's first layout: without a new identity, a window narrowed after
                // launch keeps the wide labels and everything spills into the overflow menu.
                .id(narrow)
            }
            .keptVisible()
            ToolbarItem(placement: .primaryAction) {
                NeedsYouButton(compact: narrow).id(narrow)
            }
            .keptVisible()
            ToolbarItem(placement: .primaryAction) {
                Button("Queue task", systemImage: "plus") { showsQueueTask = true }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.glassProminent)
                    .disabled(store.rig == nil || !store.isUp)
                    .keyboardShortcut("n")
                    .popover(isPresented: $showsQueueTask, arrowEdge: .bottom) {
                        if let rig = store.rig {
                            QueueTaskForm(
                                rig: rig, preselected: rig.seat(store.selection.seatID)?.sessionName,
                                done: { showsQueueTask = false }
                            )
                            .environment(store.actions)
                        }
                    }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
            }
        }
    }
}

/// Title only, or icon only when space is short.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { configuration.title }
    }
}

extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(iconOnly: Bool) -> AdaptiveLabelStyle { AdaptiveLabelStyle(iconOnly: iconOnly) }
}

extension ToolbarContent {
    /// Stays in the toolbar when the window is too narrow for every item; others go to the overflow menu first.
    @ToolbarContentBuilder func keptVisible() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

// MARK: - Sidebar

struct RigSidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedRigID) {
            Section("Rigs") {
                ForEach(store.rigs) { rig in
                    RigRow(rig: rig).tag(rig.id)
                }
            }
        }
        .overlay {
            if store.rigs.isEmpty, store.isUp {
                ContentUnavailableView(
                    "No rigs", systemImage: "square.dashed", description: Text("Start one with rig up."))
            }
        }
        .safeAreaInset(edge: .bottom) { DaemonStatusFooter() }
    }
}

struct RigRow: View {
    let rig: RigSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(rig.name)
                Text("\(rig.runningCount)/\(rig.nodeCount) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: rig.status == .running ? "circle.hexagongrid.fill" : "circle.hexagongrid")
        }
        .badge(rig.attentionCount)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(rig.name), \(rig.status.rawValue), \(rig.runningCount) of \(rig.nodeCount) seats running")
    }
}

struct DaemonStatusFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            switch store.daemon {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .running(let health):
                Image(systemName: health.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(health.isHealthy ? .green : .orange)
                Text("Daemon \(health.semver ?? "")")
                if !store.isLive {
                    Text("· polling").foregroundStyle(.secondary)
                }
            case .unreachable(_, let since):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Daemon stopped · since \(since, style: .time)")
                Spacer(minLength: 4)
                Button("Start") { Task { await store.startDaemon() } }
                    .controlSize(.small)
                    .disabled(store.actions.isRunning("daemon"))
                    .help("rig daemon start")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(footerHelp)
    }

    private var footerHelp: String {
        switch store.daemon {
        case .unreachable(let reason, _): "\(store.endpoint.baseURL.absoluteString): \(reason)"
        default: store.endpoint.baseURL.absoluteString
        }
    }
}

// MARK: - Detail

struct RigDetail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let rig = store.rig, let summary = store.selectedRig {
                Group {
                    switch store.viewMode {
                    case .canvas:
                        CanvasView()
                    case .queue:
                        QueueBoardView()
                    case .terminals:
                        TerminalsView()
                    }
                }
                .environment(rig)
                // Offline, the last data stays on screen, dimmed, with when it was current.
                .opacity(store.isUp ? 1 : 0.55)
                .safeAreaInset(edge: .top, spacing: 0) { StatusBanners(rig: rig) }
                .navigationTitle(summary.name)
                .navigationSubtitle(subtitle(rig))
            } else if case .unreachable(let reason, _) = store.daemon {
                ContentUnavailableView {
                    Label("Daemon not reachable", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Retry") { Task { await store.refreshNow() } }
                }
            } else {
                ContentUnavailableView("Select a rig", systemImage: "circle.hexagongrid")
            }
        }
    }

    private func subtitle(_ rig: RigStore) -> String {
        guard let graph = rig.graph else { return "" }
        let working = graph.seats.filter { SeatPhase($0) == .working }.count
        return
            "\(graph.seats.count) \(graph.seats.count == 1 ? "seat" : "seats") · \(working) working · \(store.isLive ? "live" : "polling")"
    }
}

struct InspectorPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        Group {
            if let rig = store.rig {
                content(rig).environment(rig)
            } else {
                empty
            }
        }
    }

    // The Queue board inspects qitems; the canvas inspects whatever was selected last.
    @ViewBuilder private func content(_ rig: RigStore) -> some View {
        let wantsItem = store.viewMode == .queue || selection.inspecting == .qitem
        if wantsItem, let item = rig.item(selection.qitemID) {
            QItemInspector(item: item).id(item.id)
        } else if let graph = rig.graph, let seat = rig.seat(selection.seatID) {
            SeatInspector(seat: seat, graph: graph).id(seat.id)
        } else {
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "No selection", systemImage: "cursorarrow.click",
            description: Text(store.viewMode == .queue ? "Select a qitem." : "Select a seat."))
    }
}

/// Daemon-down and untested-version notices above the current view.
struct StatusBanners: View {
    let rig: RigStore
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if case .unreachable(let reason, _) = store.daemon {
                banner(tint: .red, symbol: "bolt.horizontal.circle") {
                    Text("Daemon stopped. Showing data from \(stale), read-only.")
                        .help(reason)
                    Spacer()
                    ActionStatusLine(key: "daemon")
                    Button("Start daemon") { Task { await store.startDaemon() } }
                        .disabled(store.actions.isRunning("daemon"))
                        .help("rig daemon start")
                    Button("Retry") { Task { await store.refreshNow() } }
                }
            }
            if case .running(let health) = store.daemon, case .untested(let version) = health.compatibility {
                banner(tint: .orange, symbol: "exclamationmark.triangle") {
                    Text(
                        "Daemon \(version) is untested. This app was built against rig \(DaemonHealth.testedMinor.major).\(DaemonHealth.testedMinor.minor).x; some views may be wrong."
                    )
                    Spacer()
                }
            }
        }
    }

    private var stale: String {
        guard let at = rig.lastUpdated else { return "before the outage" }
        return at.formatted(date: .omitted, time: .shortened)
    }

    private func banner(tint: Color, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            content()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

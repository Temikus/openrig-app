import RigModel
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var showsInspector = true

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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
            }
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
                        ContentUnavailableView("Terminals", systemImage: "terminal", description: Text("Coming in M3."))
                    }
                }
                .environment(rig)
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
        return "\(graph.seats.count) seats · \(working) working · \(store.isLive ? "live" : "polling")"
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

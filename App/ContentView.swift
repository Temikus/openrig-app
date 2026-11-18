import RigModel
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            RigSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            RigDetail()
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
            if store.rigs.isEmpty, case .running = store.daemon {
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

/// Placeholder for the canvas (M1): the selected rig's pods and seats as a list.
struct RigDetail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let rig = store.selectedRig, let graph = store.selectedGraph {
                SeatList(graph: graph)
                    .navigationTitle(rig.name)
                    .navigationSubtitle("\(graph.seats.count) seats · \(graph.edges.count) spec edges")
            } else if case .unreachable(let reason, _) = store.daemon {
                ContentUnavailableView {
                    Label("Daemon not reachable", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Retry") { Task { await store.refreshNow() } }
                }
            } else if let error = store.graphError {
                ContentUnavailableView(
                    "Couldn't load rig", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Select a rig", systemImage: "circle.hexagongrid")
            }
        }
    }
}

struct SeatList: View {
    let graph: RigGraph

    var body: some View {
        List {
            ForEach(graph.pods) { pod in
                Section(pod.label) {
                    ForEach(graph.seats(in: pod.id)) { seat in
                        SeatRow(seat: seat)
                    }
                }
            }
        }
    }
}

struct SeatRow: View {
    let seat: Seat

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(seat.displayName).font(.body.monospaced())
                Text([seat.runtime, seat.model].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ActivityBadge(activity: seat.activity, needsAttention: seat.needsAttention)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Amber means work in flight, red means it needs you (design rule). Always paired with text.
struct ActivityBadge: View {
    let activity: AgentActivity?
    let needsAttention: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .opacity(activity?.stale == true ? 0.6 : 1)
            .help(activity?.stale == true ? "Last report is stale" : "")
    }

    private var state: ActivityState { activity?.state ?? .unknown }

    private var title: String {
        if needsAttention || state == .needsInput { return "Needs you" }
        switch state {
        case .running: return "Working"
        case .idle: return "Idle"
        default: return state == .unknown ? "Unknown" : state.rawValue
        }
    }

    private var symbol: String {
        if needsAttention || state == .needsInput { return "exclamationmark.circle.fill" }
        switch state {
        case .running: return "circle.dotted.circle"
        case .idle: return "moon.zzz"
        default: return "questionmark.circle"
        }
    }

    private var tint: Color {
        if needsAttention || state == .needsInput { return .red }
        return state == .running ? .orange : .secondary
    }
}

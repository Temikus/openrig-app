import RigClient
import RigModel
import SwiftUI

/// The asks waiting on the person, or why the phone can't show them. Task 6 makes each ask open and answerable.
struct NeedsYouView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Needs you")
                .navigationSubtitle(model.macName)
                .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder var content: some View {
        switch model.status {
        case nil where model.needs == nil:
            ProgressView("Connecting to \(model.macName)…")
        case .unreachable(let detail) where model.needs == nil:
            unavailable(
                "Can't reach \(model.macName)", systemImage: "wifi.exclamationmark",
                description: "Check that the Mac is awake with OpenRig open, and that this phone is on the same Wi-Fi.",
                detail: detail, action: retry)
        case .localNetworkDenied:
            unavailable(
                "Local Network access is off", systemImage: "network.slash",
                description:
                    "OpenRig needs Local Network access to reach your Mac on this Wi-Fi. Turn on Local Network for OpenRig in Settings.",
                action: AnyView(Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent)))
        case .unpaired:
            unavailable(
                "This phone was unpaired", systemImage: "iphone.slash",
                description: "\(model.macName) no longer accepts this phone. Pair again from OpenRig on the Mac.",
                action: AnyView(Button("Pair again") { model.unpair() }.buttonStyle(.borderedProminent)))
        case .unsupportedDaemon:
            unavailable(
                "Can't talk to \(model.macName)", systemImage: "exclamationmark.triangle",
                description:
                    "Something answered at \(model.address ?? "that address"), but not an OpenRig this app can use. Update OpenRig on the Mac, then pair again.",
                action: retry)
        default:
            list
        }
    }

    @ViewBuilder var list: some View {
        let requests = model.needs?.requests ?? []
        List {
            if case .unreachable = model.status, let lastReached = model.lastReached {
                Section {
                    Label {
                        Text(
                            "Can't reach \(model.macName). This is the list from \(lastReached, format: .dateTime.hour().minute())."
                        )
                    } icon: {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.statusBad)
                    }
                    .font(.subheadline)
                }
            }
            ForEach(requests) { request in
                AskRow(request: request)
            }
        }
        .overlay {
            if requests.isEmpty {
                ContentUnavailableView {
                    Text("Nothing needs you")
                } description: {
                    Text("Questions from your seats show up here while the app is open.")
                }
            }
        }
    }

    var retry: AnyView {
        AnyView(Button("Try again") { Task { await model.refresh() } }.disabled(model.checking))
    }

    func unavailable(
        _ title: String, systemImage: String, description: String, detail: String? = nil, action: AnyView
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        } actions: {
            action
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Who asked and what. Task 6 replaces it with the designed row.
struct AskRow: View {
    var request: AppRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.asker?.split(separator: "@").first.map(String.init) ?? "A seat").font(.headline)
            Text(request.questions.first?.question ?? request.body ?? "").lineLimit(2)
            Text(request.questions.count == 1 ? "1 question" : "\(request.questions.count) questions")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

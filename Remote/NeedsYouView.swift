import RigClient
import RigModel
import SwiftUI

/// The asks waiting on the person, or why the phone can't show them. Task 6 makes each ask open and answerable.
struct NeedsYouView: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Needs you")
                .toolbar {
                    // A custom view: navigationSubtitle drops the dot's image.
                    ToolbarItem(placement: .largeSubtitle) { MacLine() }
                }
                .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder var content: some View {
        if let requests = model.shownRequests {
            list(requests)
        } else {
            switch model.status {
            case nil:
                state { ProgressView("Connecting to \(model.macName)…") }
            case .unreachable(let detail):
                unavailable(
                    "Can't reach \(model.macName)", systemImage: "wifi.exclamationmark",
                    description:
                        "Check that the Mac is awake with OpenRig open, and that this phone is on the same Wi-Fi.",
                    detail: detail
                ) { retry }
            case .localNetworkDenied:
                unavailable(
                    "Local Network access is off", systemImage: "network.slash",
                    description:
                        "OpenRig needs Local Network access to reach your Mac on this Wi-Fi. Turn on Local Network for OpenRig in Settings."
                ) { Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent) }
            case .unpaired:
                unavailable(
                    "This phone was unpaired", systemImage: "iphone.slash",
                    description: "\(model.macName) no longer accepts this phone. Pair again from OpenRig on the Mac."
                ) { Button("Pair again") { model.unpair() }.buttonStyle(.borderedProminent) }
            case .unsupportedDaemon:
                unavailable(
                    "Can't talk to \(model.macName)", systemImage: "exclamationmark.triangle",
                    description:
                        "Something answered at \(model.address ?? "that address"), but not an OpenRig this app can use. Update OpenRig on the Mac, then pair again."
                ) { retry }
            case .noSafeAddress:
                unavailable(
                    "Wi-Fi pairing isn't ready yet", systemImage: "lock.slash",
                    description:
                        "\(model.macName) paired this phone for Wi-Fi. This version of the app can't reach a Mac on Wi-Fi without sending its key unencrypted, so it doesn't try. A later version adds an encrypted link."
                ) { EmptyView() }
            case .connected:
                // shownRequests is never nil when connected.
                EmptyView()
            }
        }
    }

    func list(_ requests: [AppRequest]) -> some View {
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
                    Text("Questions from your seats show up here. Pull down to check again.")
                }
            }
        }
    }

    var retry: some View {
        Button("Try again") { Task { await model.refresh() } }.disabled(model.checking)
    }

    /// Scrolls, so its button stays reachable at large text sizes and pull to refresh works. Centred when it fits.
    func state(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    func unavailable(
        _ title: String, systemImage: String, description: String, detail: String? = nil,
        @ViewBuilder action: () -> some View
    ) -> some View {
        state {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            } actions: {
                action()
            }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// The board's line under "Needs you": the status dot and the Mac's name. VoiceOver hears the status in words.
struct MacLine: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(StatusLabel.colour(for: model.status))
            Text(model.macName)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.macName), \(StatusLabel.words(for: model.status))")
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

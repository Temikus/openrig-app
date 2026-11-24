import RigClient
import RigModel
import SwiftUI

/// The asks waiting on the person, or why the phone can't show them. Each ask opens its question screen.
struct NeedsYouView: View {
    @Environment(RemoteSession.self) private var model
    /// Ask ids pushed on the stack.
    @State private var path = AskLink.launchPath

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Needs you")
                .toolbar {
                    // A custom view: navigationSubtitle drops the dot's image.
                    ToolbarItem(placement: .largeSubtitle) { MacLine() }
                }
                .refreshable { await model.refresh() }
                .navigationDestination(for: AskLink.self) { QuestionView(id: $0.id) }
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
                NavigationLink(value: AskLink(id: request.id)) { AskRow(request: request) }
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

/// An ask on the navigation stack, by id: the screen reads the live ask from the session.
struct AskLink: Hashable {
    var id: String

    static var launchPath: [AskLink] {
        #if DEBUG
            if let id = DebugHooks.openAsk { return [AskLink(id: id)] }
        #endif
        return []
    }
}

/// Who asked, what, and where (board 1).
struct AskRow: View {
    @Environment(RemoteSession.self) private var model
    var request: AppRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.seat).font(.headline)
            Text(request.headline).lineLimit(2)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    var caption: String {
        var parts = [request.rig].compactMap { $0 }
        parts.append(request.questions.count == 1 ? "1 question" : "\(request.questions.count) questions")
        if !model.draft(for: request).isEmpty { parts.append("draft") }
        if !request.isAnswerable { parts.append("answer on the Mac") }
        return parts.joined(separator: " · ")
    }
}

extension AppRequest {
    /// `orch-lead@openrig-app` → `orch-lead`.
    var seat: String { asker.map { String($0.prefix { $0 != "@" }) } ?? "A seat" }

    /// `orch-lead@openrig-app` → `openrig-app`.
    var rig: String? {
        guard let asker, let at = asker.firstIndex(of: "@") else { return nil }
        return String(asker[asker.index(after: at)...])
    }

    /// The ask's first line, or its first question when it has no body.
    var headline: String {
        let first = body?.split(whereSeparator: \.isNewline).first.map(String.init)
        return first ?? questions.first?.question ?? "A question"
    }
}

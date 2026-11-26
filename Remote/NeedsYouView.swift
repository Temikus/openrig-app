import RigClient
import RigModel
import SwiftUI

/// The asks waiting on the person, or why the phone can't show them. Each ask opens its question screen.
struct NeedsYouView: View {
    @Environment(RemoteSession.self) private var model
    @State private var path = NeedsLink.launchPath
    @State private var confirmingPairAgain = Self.launchConfirmingPairAgain

    static var launchConfirmingPairAgain: Bool {
        #if DEBUG
            DebugHooks.confirmPairAgain
        #else
            false
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Needs you")
                .toolbar {
                    // A custom view: navigationSubtitle drops the dot's image.
                    ToolbarItem(placement: .largeSubtitle) { MacLine() }
                }
                .refreshable { await model.refresh() }
                .navigationDestination(for: NeedsLink.self) { link in
                    switch link {
                    case .ask(let id): QuestionView(id: id)
                    case .prompt(let session): PromptView(session: session)
                    case .row(let id): RowView(id: id)
                    }
                }
        }
    }

    @ViewBuilder var content: some View {
        if let needs = model.needsYouList {
            list(needs)
        } else {
            switch model.status {
            case nil:
                state { ProgressView("Connecting to \(model.macName)…") }
            case .unreachable(let detail):
                unavailable(
                    "Can't reach \(model.macName)", systemImage: "wifi.exclamationmark",
                    description: viaRelay
                        ? "Check that the Mac is awake with OpenRig open, that “Let paired phones connect” is on in its Settings › Phone, and that this phone is on the same Wi-Fi. If you unpaired this phone on the Mac, pair it again."
                        : "Check that the Mac is awake with OpenRig open, and that this phone is on the same Wi-Fi.",
                    detail: detail
                ) {
                    retry
                    if viaRelay {
                        // "Can't reach" is often a sleeping Mac or the switch off: ask before forgetting the pairing.
                        Button("Pair Again…") { confirmingPairAgain = true }
                    }
                }
                .unpairConfirmation(isPresented: $confirmingPairAgain, .pairAgain)
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
                let onlyThisMac = model.pairing.map { NoSafeAddress($0.code) } == .onlyThisMac
                unavailable(
                    onlyThisMac ? "This pairing only works on the Mac itself" : "This pairing has no encrypted link",
                    systemImage: "lock.slash",
                    description: onlyThisMac
                        ? "\(model.macName) made this code in a build that keeps its relay on the Mac, so a phone on the Wi-Fi can't reach it. Pair again from OpenRig Canary or a release build, then unpair the old phone in that Mac's Settings › Phone."
                        : "\(model.macName) made this code before OpenRig encrypted the Wi-Fi link, and this phone won't send its key unencrypted. Pair again with a new code from the Mac, then unpair the old phone in its Settings › Phone."
                ) { Button("Pair again") { model.unpair() }.buttonStyle(.borderedProminent) }
            case .connected:
                // shownRequests is never nil when connected.
                EmptyView()
            }
        }
    }

    func list(_ needs: NeedsYouList) -> some View {
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
            // As board 5A: prompts first, since a seat is stopped until they're answered. A row only opens.
            if !needs.prompts.isEmpty {
                Section("Prompts · a seat is stopped until you answer") {
                    ForEach(needs.prompts, id: \.id) { item in
                        NavigationLink(value: NeedsLink.prompt(item.session ?? "")) { PromptRow(item: item) }
                    }
                }
            }
            if !needs.asks.isEmpty {
                section(needs.prompts.isEmpty ? nil : "Asks") {
                    ForEach(needs.asks) { request in
                        NavigationLink(value: NeedsLink.ask(request.id)) { AskRow(request: request) }
                    }
                }
            }
            if !needs.rows.isEmpty {
                section(needs.prompts.isEmpty && needs.asks.isEmpty ? nil : "For you") {
                    ForEach(needs.rows, id: \.id) { item in
                        NavigationLink(value: NeedsLink.row(item.row ?? "")) { ItemRow(item: item) }
                    }
                }
            }
            if !needs.seatsDown.isEmpty {
                Section("Seats down") {
                    ForEach(needs.seatsDown, id: \.id) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text("\(item.rig) · start it on the Mac").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.attention)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            // Other rigs' prompts and seats down aren't listed one by one: the Mac shows them on that rig's seats.
            if !needs.elsewhere.isEmpty {
                Section {
                    ForEach(needs.elsewhere, id: \.rig) { other in
                        Text(
                            "\(other.count) more in \(other.rig): \(other.count == 1 ? "a prompt or a seat down" : "prompts or seats down"). See that rig's seats on the Mac."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if needs.isEmpty {
                ContentUnavailableView {
                    Text("Nothing needs you")
                } description: {
                    Text("Questions from your seats show up here while the app is open.")
                }
            }
        }
    }

    /// A header only when another section comes first, so a list of only asks looks as before.
    @ViewBuilder func section(_ header: String?, @ViewBuilder _ content: () -> some View) -> some View {
        if let header { Section(header) { content() } } else { Section { content() } }
    }

    /// Paired through the Mac's relay. After Unpair the relay refuses the phone's key, and iOS doesn't always report
    /// the refusal: sometimes the handshake just stalls, which reads as out of reach.
    var viaRelay: Bool { model.pairing?.code.reaches.contains { $0.kind == .lan } == true }

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

/// A screen on Needs you's stack, by id: each screen reads the live ask, prompt or row from the session.
enum NeedsLink: Hashable {
    case ask(String)
    /// A seat stopped at a prompt, by session.
    case prompt(String)
    /// A row answered with Reply, Got it or Done, by row id.
    case row(String)

    static var launchPath: [NeedsLink] {
        #if DEBUG
            if let id = DebugHooks.openAsk { return [.ask(id)] }
            if let session = DebugHooks.openPrompt { return [.prompt(session)] }
            if let id = DebugHooks.openRow { return [.row(id)] }
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

/// A seat stopped at a prompt: who, the start of the command, and where (board 5A, A1). It only opens the prompt.
struct PromptRow: View {
    var item: RelayNeedsYouItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline)
            if let command = item.detail {
                Text(command).font(.footnote.monospaced()).lineLimit(3)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    var caption: String {
        let lines = item.detail?.split(whereSeparator: \.isNewline).count ?? 0
        return lines > 3 ? "\(item.rig) · \(lines) lines" : item.rig
    }
}

/// An FYI, an ask without options, or a row held on the person.
struct ItemRow: View {
    var item: RelayNeedsYouItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.sender).font(.headline)
            Text(item.title).lineLimit(2)
            Text("\(item.rig) · \(item.kindWords)").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension RelayNeedsYouItem {
    /// `orch-lead@openrig-app` → `orch-lead`.
    var sender: String { session.map { String($0.prefix { $0 != "@" }) } ?? "A seat" }

    var kindWords: String {
        switch kind {
        case "fyi": "for your information"
        case "held": "waiting on you"
        default: "asks you"
        }
    }
}

extension AppRequest {
    /// `orch-lead@openrig-app` → `orch-lead`.
    var seat: String { asker.map { String($0.prefix { $0 != "@" }) } ?? "A seat" }

    /// `orch-lead@openrig-app` → `openrig-app`.
    var rig: String? { askerRig }

    /// The ask's first line, or its first question when it has no body.
    var headline: String {
        let first = body?.split(whereSeparator: \.isNewline).first.map(String.init)
        return first ?? questions.first?.question ?? "A question"
    }
}

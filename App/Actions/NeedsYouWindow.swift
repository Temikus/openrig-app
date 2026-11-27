import RigDomain
import RigModel
import SwiftUI

/// Every rig's asks of the person in one list, the opened ask beside it. Permission prompts and down seats stay in
/// the toolbar's Needs you list, which knows the selected rig's panes.
struct NeedsYouWindow: View {
    static let id = "needs-you"
    #if DEBUG
        static let opensAtLaunch = debugMode.hasPrefix("queue")
        private static var debugMode: String { ProcessInfo.processInfo.environment["OPENRIG_DEBUG_NEEDS_YOU"] ?? "" }
    #else
        static let opensAtLaunch = false
    #endif
    @Environment(AppStore.self) private var app
    @State private var selected: QItem.ID?

    var body: some View {
        let asks = app.humanQueue
        NavigationSplitView {
            // Redraws every 30 s so each row's age stays true.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List(asks, selection: $selected) { item in
                    // The date is an input, so the list redraws each row as it ticks.
                    AskRow(item: item, me: app.me, now: context.date)
                }
            }
            .overlay {
                if asks.isEmpty {
                    ContentUnavailableView(
                        "Nothing needs you", systemImage: "checkmark.circle",
                        description: Text("Asks from every rig show here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            // A decided ask leaves the list, and its detail with it.
            if let item = asks.first(where: { $0.id == selected }) {
                AskDetail(item: item).id(item.id)
            } else if !asks.isEmpty {
                ContentUnavailableView("Open an ask", systemImage: "tray")
            }
        }
        .navigationTitle(asks.isEmpty ? "Needs You" : "Needs You · \(asks.count)")
        .environment(app.actions)
        .environment(app.selection)
        .frame(minWidth: 720, minHeight: 420)
        #if DEBUG
            .onAppear {
                if Self.debugMode.hasPrefix("queue/") { selected = String(Self.debugMode.dropFirst("queue/".count)) }
            }
        #endif
    }
}

/// An ask's TL;DR, then its rig, the seat that asked and how long ago.
private struct AskRow: View {
    let item: QItem
    let me: String
    let now: Date

    var body: some View {
        let asker = askedBy(item, me: me)
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary.isEmpty ? "No summary" : item.summary).lineLimit(2)
                Text(subtitle(asker: asker)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(forYou(item, me: me) == .update ? Color.secondary : .attention)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch forYou(item, me: me) {
        case .update?: "envelope"
        case .decision?: "person.fill.questionmark"
        case nil: "hand.raised"
        }
    }

    private func subtitle(asker: String) -> String {
        let seat = asker.split(separator: "@").first.map(String.init) ?? asker
        var parts = [rigName(ofSession: asker) ?? "", seat].filter { !$0.isEmpty }
        if let asked = item.created ?? item.updated { parts.append(relative(asked, to: now)) }
        return parts.joined(separator: " · ")
    }
}

/// "3 minutes ago".
private func relative(_ date: Date, to now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
}

/// The opened ask: its TL;DR, its context, and the same answer controls the inspector shows, against the asking
/// rig's own store so Tell and Reply… reach the seat.
private struct AskDetail: View {
    let item: QItem
    @Environment(AppStore.self) private var app
    @State private var store: RigStore?
    @State private var images: RowImages?

    var body: some View {
        let asker = askedBy(item, me: app.me)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.summary.isEmpty ? "No summary" : item.summary)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    HStack {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(byline(asker: asker, now: context.date)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open the seat") { app.openSeat(session: asker) }
                            .help("Shows \(name(asker)) on Terminals in the main window")
                    }
                    .font(.callout)
                }
                RowBody(item: item, title: "Context")
                if let store {
                    answer.environment(store)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(16, for: .scrollContent)
        .environment(\.rowImages, images)
        .task(id: item.id) {
            guard let name = rigName(ofSession: asker), let fresh = app.rigStore(named: name) else { return }
            if fresh !== app.rig { await fresh.refresh() }
            store = fresh
            images = await fresh.images(for: item, launchFolder: nil)
            if let folder = await fresh.launchFolder(session: item.source) {
                images = await fresh.images(for: item, launchFolder: folder)
            }
        }
    }

    /// A row to the person gets the For You panel; a row held on them is resolved, as on the queue board.
    @ViewBuilder private var answer: some View {
        if let kind = forYou(item, me: app.me) {
            ForYouPanel(item: item, kind: kind)
        } else if workStatus(item).needsYou {
            ResolvePanel(item: item) {}
        } else {
            QItemActions(item: item)
        }
    }

    private func name(_ session: String) -> String {
        store?.displayName(session: session) ?? session.split(separator: "@").first.map(String.init) ?? session
    }

    private func byline(asker: String, now: Date) -> String {
        var parts = [rigName(ofSession: asker) ?? "", name(asker)].filter { !$0.isEmpty }
        if let asked = item.created ?? item.updated {
            parts.append("asked " + relative(asked, to: now))
        }
        return parts.joined(separator: " · ")
    }
}

import RigDomain
import RigModel
import SwiftUI

/// The rig's queue as a board: Pending, In progress, Blocked, Done (Closed and Handed off).
struct QueueBoardView: View {
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @Environment(AppStore.self) private var app
    @State private var filter = BoardFilter(scope: Self.initialScope)

    /// Active, or OPENRIG_DEBUG_SCOPE=today in debug builds for screenshots of closed work.
    private static var initialScope: BoardFilter.Scope {
        #if DEBUG
            if ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SCOPE"] == "today" { return .today }
        #endif
        return .active
    }
    /// The board's width; four columns share it.
    @State private var visibleWidth: CGFloat = 1000
    @FocusState private var searching: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let columns = board(rig.items, filter: filter, now: now)
            VStack(alignment: .leading, spacing: 0) {
                // Scrolls rather than squeezes: fixed-size controls here would otherwise set the detail
                // column's minimum width, which the split view can't satisfy beside the inspector.
                // The search stays in view at the trailing edge; when narrow, only the filters scroll under it. An
                // overlay, so its width never feeds the detail column's size, which would squeeze the sidebar.
                ScrollView(.horizontal) { filterRow(now: now) }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // Fades out at the trailing edge, the cue that more filters scroll in from under the search.
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                        }
                    }
                    .padding(.trailing, BoardSearchField.width + 28)
                    .overlay(alignment: .bottomTrailing) {
                        BoardSearchField(text: $filter.search, focused: $searching)
                            .padding(.trailing, 16)
                    }
                    // No preferred width of its own: the split view sizes the detail column toward its content's ideal
                    // width when the window resizes, and a wide filter row would squeeze the sidebar for it.
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                // Below 720 pt the strip folds into the toolbar's Needs-you popover.
                let asks = rig.needsYou
                if !asks.isEmpty && visibleWidth >= 720 {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(asks) { NeedsYouRow(entry: $0).frame(width: 380) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    }
                    .scrollIndicators(.never)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        BoardColumn(title: "Pending", items: columns.pending, now: now, emptyHint: noMatches)
                        BoardColumn(title: "In progress", items: columns.inProgress, now: now, emptyHint: noMatches)
                        BoardColumn(title: "Blocked", items: columns.blocked, now: now, emptyHint: noMatches)
                        BoardColumn(
                            title: "Done", items: columns.closed, now: now,
                            secondTitle: "Handed off", secondItems: columns.handedOff,
                            emptyHint: noMatches
                                ?? (filter.scope == .active ? "Switch to Today to see closed work." : nil))
                    }
                    .padding(16)
                }
                // The split view already places this beside the sidebar and inspector. Its safe-area insets
                // still report both, so subtracting them would count them twice.
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    visibleWidth = $0
                }
                // Below 220 pt a column, the board scrolls sideways instead of squeezing.
                .environment(\.boardColumnWidth, max(220, (visibleWidth - 32 - 3 * 14) / 4 - 20))
            }
        }
        // In the filter row, beside the other filters: a toolbar search lands over the inspector, away from the board.
        // ⌘F is the View menu's Search Queue, which switches here first.
        .onChange(of: app.wantsSearch, initial: true) { _, wants in
            guard wants else { return }
            app.wantsSearch = false
            // After this update, so a board that has only just appeared can take focus.
            Task { @MainActor in searching = true }
        }
    }

    /// While a search is active, an empty column says so, rather than looking like an empty queue.
    private var noMatches: String? {
        let query = filter.search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : "No matches for “\(query)”."
    }

    private func filterRow(now: Date) -> some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $filter.scope) {
                ForEach(BoardFilter.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Seat", selection: $filter.seat) {
                Text("All seats").tag(String?.none)
                ForEach(rig.graph?.seats ?? []) { seat in
                    if let session = seat.sessionName {
                        Text(seat.displayName).tag(String?.some(session))
                    }
                }
            }
            .fixedSize()

            Toggle("Overdue only", isOn: $filter.overdueOnly)
                .toggleStyle(.checkbox)

            Spacer()
            let overdue = rig.items.filter { isOverdue($0, now: now) }.count
            if overdue > 0 {
                Label("\(overdue) overdue", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .padding(.leading, 16)
        .padding(.top, 12)
    }
}

/// The board's search, in its filter row. ⌘F focuses it.
struct BoardSearchField: View {
    static let width: CGFloat = 200
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search queue", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                // Escape clears; on an empty field it leaves it, as macOS search fields do.
                .onExitCommand {
                    if text.isEmpty { focused.wrappedValue = false } else { text = "" }
                }
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Text("⌘F").font(.caption.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused.wrappedValue ? Color.accentColor : .clear, lineWidth: 2)
        }
        .help("Search this rig's queue (⌘F)")
    }
}

struct BoardColumn: View {
    @Environment(\.boardColumnWidth) private var width
    let title: String
    let items: [QItem]
    let now: Date
    var secondTitle: String?
    var secondItems: [QItem] = []
    var emptyHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title, items.count)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { QItemCard(item: $0, now: now) }
                    if let secondTitle, !secondItems.isEmpty {
                        header(secondTitle, secondItems.count).padding(.top, 8)
                        ForEach(secondItems) { QItemCard(item: $0, now: now) }
                    }
                    if items.isEmpty && secondItems.isEmpty {
                        Text(emptyHint ?? "Nothing here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct QItemCard: View {
    let item: QItem
    let now: Date
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection

    private var status: WorkStatus { workStatus(item) }
    private var forYou: ForYou? { RigDomain.forYou(item, me: rig.me) }
    private var isSelected: Bool { selection.qitemID == item.id }
    private var border: Color {
        if isSelected { return .accentColor }
        return status.needsYou || forYou == .decision ? Color.attention : Color(nsColor: .separatorColor)
    }

    var body: some View {
        Button {
            selection.select(qitem: item.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(shortQItemID(item.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    // A finished row's outcome sits by the id: a narrow or scrolled Done column cuts off the trailing edge.
                    if let ended = RigDomain.outcome(item) {
                        StatusTag(status: status, outcome: ended)
                        Spacer()
                    } else {
                        Spacer()
                        StatusTag(status: status, overdue: isOverdue(item, now: now), forYou: forYou)
                    }
                }
                Text(item.summary.isEmpty ? "No summary" : item.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if !status.isActive, let updated = item.updated {
                        Text(closedAt(updated))
                        Text("·")
                    }
                    Text(rig.displayName(session: item.source))
                    Image(systemName: "arrow.right").imageScale(.small)
                    Text(rig.displayName(session: item.destination))
                    Spacer()
                    if let closeBy = item.closeBy, status.isActive {
                        Text("close by \(closeBy, style: .time)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                blockerLine
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 9))
            // One ring: selection replaces the red needs-you border instead of circling it.
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(border, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(item.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var blockerLine: some View {
        switch status {
        case .blocked(on: .outside(let ref)):
            Label(
                ref == rig.me || Human.isYou(ref) ? "on you" : "on you · \(ref)",
                systemImage: "person.fill.questionmark"
            )
            .font(.caption)
            .foregroundStyle(Color.attention)
            .lineLimit(1)
        case .blocked(on: .qitem(let id)):
            Button("held on \(shortQItemID(id))", systemImage: "link") { selection.select(qitem: id) }
                .buttonStyle(.link)
                .font(.caption)
        case .handedOff(let to):
            let next = rig.chains.chain(for: item.id)
            let successor = next.links.indices.contains(next.focusIndex + 1) ? next.links[next.focusIndex + 1].id : nil
            if let successor {
                Button("→ \(to.map(rig.displayName(session:)) ?? "next") · \(shortQItemID(successor))") {
                    selection.select(qitem: successor)
                }
                .buttonStyle(.link)
                .font(.caption)
            } else if let to {
                Text("→ \(rig.displayName(session: to))").font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

/// State as a word with a colour. Amber is work in flight, red needs you.
/// When a row finished: the time today, the date and time before that.
func closedAt(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .shortened)
}

struct StatusTag: View {
    let status: WorkStatus
    var overdue = false
    /// Set for a live row addressed to the person, which reads as theirs rather than as pending work.
    var forYou: ForYou?
    /// A finished row's outcome, from the row (its resolution tells an approval from a plain close).
    var outcome: Outcome?

    var body: some View {
        HStack(spacing: 6) {
            if overdue {
                Text("overdue").foregroundStyle(.orange)
            }
            if let ended {
                // A finished row's outcome in one word, as a tinted capsule so it reads apart from live states.
                Text(ended.label)
                    .foregroundStyle(endedColor(ended))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(endedColor(ended).opacity(0.14), in: .capsule)
            } else {
                Text(label).foregroundStyle(color)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var ended: Outcome? { outcome }

    private func endedColor(_ o: Outcome) -> Color {
        switch o {
        case .approved: .approved
        case .denied: .attention
        default: .secondary
        }
    }

    private var label: String {
        switch forYou {
        case .decision?: return "Asks you"
        case .update?: return "FYI"
        case nil: break
        }
        return switch status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .blocked(on: .outside): "Needs you"
        case .blocked(on: .qitem): "Held"
        case .closed(let reason): reason.map { "Closed · \($0)" } ?? "Closed"
        case .handedOff: "Handed off"
        case .unknown(let raw): raw
        }
    }

    private var color: Color {
        if let forYou { return forYou == .decision ? Color.attention : .secondary }
        return switch status {
        case .inProgress: .orange
        case .blocked(on: .outside): .attention
        case .closed, .handedOff: .secondary
        default: .primary
        }
    }
}

extension EnvironmentValues {
    @Entry var boardColumnWidth: CGFloat = 280
}

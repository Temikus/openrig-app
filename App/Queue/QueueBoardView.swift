import RigDomain
import RigModel
import SwiftUI

/// The rig's queue as a board: Pending, In progress, Blocked, Done (Closed and Handed off).
struct QueueBoardView: View {
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @State private var filter = BoardFilter()
    /// Width not covered by the floating inspector; four columns share it.
    @State private var visibleWidth: CGFloat = 1000

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let columns = board(rig.items, filter: filter, now: now)
            VStack(alignment: .leading, spacing: 0) {
                filterRow(now: now)
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
                        BoardColumn(title: "Pending", items: columns.pending, now: now)
                        BoardColumn(title: "In progress", items: columns.inProgress, now: now)
                        BoardColumn(title: "Blocked", items: columns.blocked, now: now)
                        BoardColumn(
                            title: "Done", items: columns.closed, now: now,
                            secondTitle: "Handed off", secondItems: columns.handedOff,
                            emptyHint: filter.scope == .active ? "Switch to Today to see closed work." : nil)
                    }
                    .padding(16)
                }
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.size.width - geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing
                } action: {
                    visibleWidth = $0
                }
                // Below 220 pt a column, the board scrolls sideways instead of squeezing.
                .environment(\.boardColumnWidth, max(220, (visibleWidth - 32 - 3 * 14) / 4 - 20))
            }
        }
        .searchable(text: $filter.search, placement: .toolbar, prompt: "Search qitems")
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
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
    private var isSelected: Bool { selection.qitemID == item.id }

    var body: some View {
        Button {
            selection.select(qitem: item.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(shortQItemID(item.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    StatusTag(status: status, overdue: isOverdue(item, now: now))
                }
                Text(item.summary.isEmpty ? "No summary" : item.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
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
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(status.needsYou ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(item.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var blockerLine: some View {
        switch status {
        case .blocked(on: .outside(let ref)):
            Label("on you · \(ref)", systemImage: "person.fill.questionmark")
                .font(.caption)
                .foregroundStyle(.red)
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
struct StatusTag: View {
    let status: WorkStatus
    var overdue = false

    var body: some View {
        HStack(spacing: 6) {
            if overdue {
                Text("overdue").foregroundStyle(.orange)
            }
            Text(label).foregroundStyle(color)
        }
        .font(.caption.weight(.semibold))
    }

    private var label: String {
        switch status {
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
        switch status {
        case .inProgress: .orange
        case .blocked(on: .outside): .red
        case .closed, .handedOff: .secondary
        default: .primary
        }
    }
}

extension EnvironmentValues {
    @Entry var boardColumnWidth: CGFloat = 280
}

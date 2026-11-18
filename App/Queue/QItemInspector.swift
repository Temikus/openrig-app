import RigDomain
import RigModel
import SwiftUI

struct QItemInspector: View {
    let item: QItem
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        // Redraws every 30 s so "Created 3 minutes ago" stays true.
        TimelineView(.periodic(from: .now, by: 30)) { _ in content }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(shortQItemID(item.id)).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        StatusTag(status: workStatus(item), overdue: isOverdue(item, now: .now))
                    }
                    Text(item.summary.isEmpty ? "No summary" : item.summary)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Owner", rig.displayName(session: item.destination))
                    row("From", rig.displayName(session: item.source))
                    if let closeBy = item.closeBy {
                        row("Close by", closeBy.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let priority = item.priority { row("Priority", priority) }
                    if let created = item.created { row("Created", relative(created)) }
                    if let updated = item.updated { row("Updated", relative(updated)) }
                    if let blocked = item.blockedOn { row("Blocked on", blocked) }
                    if let hop = rig.nextHop(for: item.id) {
                        row("Next", "\(hop.nextStepID) · \(rig.displayName(session: hop.owner))")
                    }
                    if let resolution = item.resolution { row("Resolution", resolution) }
                }
                .font(.callout)

                if workStatus(item).isActive {
                    QItemActions(item: item)
                }

                ChainOfRecordView(chain: rig.chains.chain(for: item.id))

                if let body = item.body, !body.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body").font(.headline)
                        Text(body)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Margins on the scroll content, not padding inside it, so the inspector's own insets are respected.
        .contentMargins(16, for: .scrollContent)
    }

    /// "3 minutes ago". Re-evaluated whenever the inspector redraws, which the 30 s timeline forces.
    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// The item's handoffs, oldest first. The selected item is marked; ancestors not loaded show by id.
struct ChainOfRecordView: View {
    let chain: Chain
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        if chain.links.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Chain of record").font(.headline)
                    Text(chain.links.count == 2 ? "1 hop" : "\(chain.links.count - 1) hops").foregroundStyle(.secondary)
                    if chain.branchCount > 0 {
                        Text("· \(chain.branchCount) branch\(chain.branchCount == 1 ? "" : "es")")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(chain.links.enumerated()), id: \.element.id) { index, link in
                    Button {
                        selection.select(qitem: link.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: index == chain.focusIndex ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(index == chain.focusIndex ? Color.orange : .secondary)
                                .imageScale(.small)
                            Text(shortQItemID(link.id)).font(.caption.monospaced())
                            switch link {
                            case .loaded(let item):
                                Text(rig.displayName(session: item.destination)).font(.callout)
                                Spacer()
                                StatusTag(status: workStatus(item))
                            case .missing:
                                Text("not loaded").font(.callout).foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == chain.focusIndex)
                    .help(link.id)
                }
            }
        }
    }
}

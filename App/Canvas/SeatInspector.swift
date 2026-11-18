import RigModel
import SwiftUI

struct SeatInspector: View {
    let seat: Seat
    let graph: RigGraph
    @Environment(SelectionStore.self) private var selection
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", spec = "Spec"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(phase: SeatPhase(seat))
                    Text(seat.displayName).font(.title2.weight(.semibold))
                }
                Text([seat.sessionName, seat.model.map(shortModelName)].compactMap(\.self).joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                switch tab {
                case .overview: overview
                case .spec: spec
                }
            }
        }
        .padding(16)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Activity", activityText)
                row("Status", seat.status.rawValue)
                row("Runtime", seat.runtime ?? "—")
                row("Context used", seat.contextUsedPercent.map { "\($0)%" } ?? "—")
                row(
                    "Work",
                    "\(seat.work.inProgress) in progress · \(seat.work.pending) pending · \(seat.work.blocked) blocked")
                row("tmux", [seat.sessionName, seat.tmuxPane].compactMap(\.self).joined(separator: " "))
                if let held = seat.heldReason { row("Held", held) }
            }
            .font(.callout)

            if !seat.currentQItems.isEmpty {
                Text("In progress").font(.headline)
                ForEach(seat.currentQItems) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shortQItemID(item.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .help(item.id)
                        Text(item.bodyExcerpt).font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityText: String {
        let phase = SeatPhase(seat)
        var text = phase.label
        if let reason = seat.activity?.reason { text += " (\(reason.replacingOccurrences(of: "_", with: " ")))" }
        if let age = compactAge(since: seat.activity?.since, now: .now) { text += " · \(age)" }
        return text
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var spec: some View {
        VStack(alignment: .leading, spacing: 14) {
            relation(
                "Delegates to", graph.edges.filter { $0.source == seat.id && $0.kind == .delegatesTo }.map(\.target))
            relation(
                "Takes work from", graph.edges.filter { $0.target == seat.id && $0.kind == .delegatesTo }.map(\.source))
            relation("Observes", graph.edges.filter { $0.source == seat.id && $0.kind == .canObserve }.map(\.target))
            relation("Observed by", graph.edges.filter { $0.target == seat.id && $0.kind == .canObserve }.map(\.source))
            let other = graph.edges.filter {
                ($0.source == seat.id || $0.target == seat.id) && $0.kind != .delegatesTo && $0.kind != .canObserve
            }
            ForEach(other) { edge in
                let peer = edge.source == seat.id ? edge.target : edge.source
                relation(edge.kind.rawValue.replacingOccurrences(of: "_", with: " "), [peer])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func relation(_ title: String, _ seatIDs: [Seat.ID]) -> some View {
        if !seatIDs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(seatIDs, id: \.self) { id in
                    let peer = graph.seats.first { $0.id == id }
                    Button(peer?.displayName ?? id) { selection.seatID = id }
                        .buttonStyle(.link)
                        .font(.callout.monospaced())
                }
            }
        }
    }
}

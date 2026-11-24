import RigDomain
import RigModel
import SwiftUI

/// Rig › Go to… (⌘K): type part of a rig, seat or task name, then Return to go there. ↑↓ move through the matches;
/// Esc closes. Seats and tasks are the selected rig's (other rigs' aren't loaded); tasks closed before today aren't listed.
struct GoToPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The highlighted row's id, so rows arriving while the palette is open don't move the highlight.
    @State private var highlightedID: String?
    @FocusState private var fieldFocused: Bool

    private var items: [GoToItem] {
        var items = store.rigs.filter { !$0.isArchived }.map {
            GoToItem(kind: .rig, id: $0.id, title: $0.name, detail: "\($0.nodeCount) seats")
        }
        if let rig = store.rig {
            items += (rig.graph?.seats ?? []).map {
                GoToItem(kind: .seat, id: $0.id, title: $0.displayName, detail: rig.rigName)
            }
            items += rig.items.map { GoToItem(task: $0) }
        }
        return items
    }

    var body: some View {
        let matches = goToMatches(query, in: items)
        let highlighted = goToHighlight(highlightedID, in: matches)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Go to a rig, seat or task", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { if matches.indices.contains(highlighted) { go(matches[highlighted]) } }
                    .onKeyPress(.downArrow) {
                        if !matches.isEmpty { highlightedID = matches[min(highlighted + 1, matches.count - 1)].id }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if !matches.isEmpty { highlightedID = matches[max(highlighted - 1, 0)].id }
                        return .handled
                    }
            }
            .padding(14)
            Divider()
            if matches.isEmpty {
                Text("No matches for “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == highlighted)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: highlighted) { proxy.scrollTo(matches[highlighted].id) }
                }
            }
        }
        .frame(width: 520)
        .onAppear { fieldFocused = true }
        // Tasks are the rig's open rows plus today's closed ones, read while the palette is open.
        .task { await store.rig?.holdClosedRows() }
        .onChange(of: query) { highlightedID = nil }
    }

    private func row(_ item: GoToItem, highlighted: Bool) -> some View {
        Button {
            go(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isClosed ? "checkmark.circle" : symbol(item.kind))
                    .frame(width: 18)
                    .foregroundStyle(highlighted ? Color.white : .secondary)
                    .accessibilityHidden(true)
                Text(item.title).fontWeight(.medium).lineLimit(1)
                Text(item.detail)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(highlighted ? Color.white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(highlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func symbol(_ kind: GoToItem.Kind) -> String {
        switch kind {
        case .rig: "circle.hexagongrid"
        case .seat: "person.crop.square"
        case .task: "tray"
        }
    }

    private func go(_ item: GoToItem) {
        switch item.kind {
        case .rig:
            store.selectedRigID = item.id
        case .seat:
            if let rig = store.rig, let seat = rig.seat(item.id) { store.reveal(seat: seat, in: rig) }
        case .task:
            store.reveal(qitem: item.id)
        }
        dismiss()
    }
}

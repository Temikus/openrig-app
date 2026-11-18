import AppKit
import RigDomain
import RigModel
import RigTerminal
import SwiftUI

/// Every seat's terminal as a tile, fitted to the window. Seats that need you or are working share the
/// top rows; idle seats get short tiles below. Snapshots refresh every second; the focused tile is a live
/// tmux client.
struct TerminalsView: View {
    @Environment(RigStore.self) private var rig
    /// The order when focus began. Nothing moves while a tile has focus, except that a seat with a new
    /// prompt still gets a large tile, appended after the others.
    @State private var frozen: FrozenOrder?
    @State private var keyMonitor: Any?

    private var terminals: TerminalStore { rig.terminals }

    private enum Metrics {
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 14
        static let largeMinWidth: CGFloat = 460
        static let largeMinHeight: CGFloat = 260
        static let smallMinWidth: CGFloat = 230
        static let smallHeight: CGFloat = 190
    }

    var body: some View {
        Group {
            if terminals.tmux == nil {
                ContentUnavailableView(
                    "tmux not found", systemImage: "terminal",
                    description: Text("Install tmux (brew install tmux) to see seat terminals."))
            } else if let graph = rig.graph {
                // GeometryReader takes the space offered and nothing inside can grow it. The grid is sized
                // from it, so measuring the content instead would feed back into the window size.
                GeometryReader { geo in
                    ScrollView { grid(graph, viewport: geo.size).padding(Metrics.padding) }
                }
                .task(id: rig.rigID) {
                    await terminals.run { rig.graph?.seats.compactMap(\.tmuxPane) ?? [] }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            terminals.release()
            frozen = nil
        }
        .onChange(of: terminals.focusedSeatID) { _, focused in
            guard let graph = rig.graph else { return }
            if focused == nil {
                frozen = nil
            } else if frozen == nil {
                let large = largeByState(graph)
                frozen = FrozenOrder(large: large, small: graph.seats.map(\.id).filter { !large.contains($0) })
            }
        }
    }

    private func grid(_ graph: RigGraph, viewport: CGSize) -> some View {
        let width = max(0, viewport.width - 2 * Metrics.padding)
        let (large, small) = arrangement(graph)
        terminals.order = large.map(\.id) + small.compactMap { $0.isPlaceholder ? nil : $0.seat.id }

        let smallCols = columns(small.count, width: width, min: Metrics.smallMinWidth)
        let smallRows = rows(small.count, cols: smallCols)
        let largeCols = columns(large.count, width: width, min: Metrics.largeMinWidth)
        let largeRows = rows(large.count, cols: largeCols)

        // Large tiles share whatever height the small rows leave; with no large tiles, small ones do.
        let available = viewport.height - 2 * Metrics.padding
        let smallBlock =
            small.isEmpty ? 0 : CGFloat(smallRows) * Metrics.smallHeight + CGFloat(smallRows) * Metrics.spacing
        let largeHeight =
            large.isEmpty ? 0 : max(Metrics.largeMinHeight, share(available - smallBlock, rows: largeRows))
        let smallHeight =
            large.isEmpty ? max(Metrics.smallHeight, share(available, rows: smallRows)) : Metrics.smallHeight

        return VStack(alignment: .leading, spacing: Metrics.spacing) {
            tileRows(large.map { Slot(seat: $0) }, cols: largeCols, width: width, height: largeHeight, isLarge: true)
            tileRows(small, cols: smallCols, width: width, height: smallHeight, isLarge: false)
        }
        // A click between tiles releases focus.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { terminals.release() })
    }

    /// Large tiles, then small slots. While focus is held, a seat that moved up leaves a placeholder below.
    private func arrangement(_ graph: RigGraph) -> (large: [Seat], small: [Slot]) {
        let seat = { (id: Seat.ID) in graph.seats.first { $0.id == id } }
        guard let frozen else {
            let large = largeByState(graph)
            return (large.compactMap(seat), graph.seats.filter { !large.contains($0.id) }.map { Slot(seat: $0) })
        }
        var largeIDs = frozen.large.filter { seat($0) != nil }
        for prompt in rig.prompts where !largeIDs.contains(prompt.seatID) { largeIDs.append(prompt.seatID) }
        if let focused = terminals.focusedSeatID, !largeIDs.contains(focused) { largeIDs.append(focused) }
        var small = frozen.small.compactMap(seat).map { Slot(seat: $0, isPlaceholder: largeIDs.contains($0.id)) }
        let known = Set(frozen.large + frozen.small)
        small += graph.seats.filter { !known.contains($0.id) && !largeIDs.contains($0.id) }.map { Slot(seat: $0) }
        return (largeIDs.compactMap(seat), small)
    }

    @ViewBuilder
    private func tileRows(_ slots: [Slot], cols: Int, width: CGFloat, height: CGFloat, isLarge: Bool) -> some View {
        let tileWidth = (width - CGFloat(cols - 1) * Metrics.spacing) / CGFloat(max(cols, 1))
        ForEach(Array(stride(from: 0, to: slots.count, by: max(cols, 1))), id: \.self) { start in
            HStack(alignment: .top, spacing: Metrics.spacing) {
                ForEach(slots[start..<min(start + cols, slots.count)], id: \.seat.id) { slot in
                    Group {
                        if slot.isPlaceholder {
                            PlaceholderTile(seat: slot.seat)
                        } else {
                            TerminalTile(seat: slot.seat, large: isLarge)
                        }
                    }
                    .frame(width: max(0, tileWidth), height: height)
                }
            }
        }
    }

    private func columns(_ count: Int, width: CGFloat, min: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        return Swift.max(1, Swift.min(count, Int((width + Metrics.spacing) / (min + Metrics.spacing))))
    }

    private func rows(_ count: Int, cols: Int) -> Int { count == 0 ? 0 : (count + cols - 1) / cols }

    private func share(_ height: CGFloat, rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return (height - CGFloat(rows - 1) * Metrics.spacing) / CGFloat(rows)
    }

    /// Prompts first, oldest first (each stalls a turn), then other seats that need you, then working ones.
    private func largeByState(_ graph: RigGraph) -> [Seat.ID] {
        var ids = rig.needsYou.compactMap { entry -> Seat.ID? in
            if case .prompt(let prompt, _) = entry { prompt.seatID } else { nil }
        }
        for phase in [SeatPhase.needsYou, .working] {
            ids += graph.seats.filter { SeatPhase($0) == phase && !ids.contains($0.id) }.map(\.id)
        }
        return ids
    }

    /// Keys for this view: Esc leaves Type mode (so a stray Esc never interrupts a turn), and a second Esc
    /// releases focus unless a text field is being edited. ⌘] and ⌘[ move focus in display order; ⌘T
    /// toggles Type mode on the focused tile. There is no key for Allow once: a stray key must not approve.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let terminals = self.terminals
        let rig = self.rig
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            switch (event.keyCode, command) {
            case (53, false):  // Esc
                if terminals.typing {
                    terminals.typing = false
                    return nil
                }
                let editing = event.window?.firstResponder is NSText
                guard terminals.focusedSeatID != nil, !editing else { return event }
                terminals.release()
                return nil
            case (30, true), (33, true):  // ⌘] next, ⌘[ previous
                let order = terminals.order
                guard !order.isEmpty else { return event }
                let current = terminals.focusedSeatID.flatMap { order.firstIndex(of: $0) }
                let step = event.keyCode == 30 ? 1 : -1
                let next = current.map { ($0 + step + order.count) % order.count } ?? (step > 0 ? 0 : order.count - 1)
                if let seat = rig.seat(order[next]) { terminals.focus(seat) }
                return nil
            case (17, true):  // ⌘T
                guard terminals.focusedSeatID != nil else { return event }
                terminals.typing.toggle()
                return nil
            default:
                return event
            }
        }
    }
}

private struct FrozenOrder: Equatable {
    var large: [Seat.ID]
    var small: [Seat.ID]
}

private struct Slot {
    var seat: Seat
    var isPlaceholder = false
}

/// Holds a small tile's place while its seat is focused in the large row, so nothing below moves.
private struct PlaceholderTile: View {
    let seat: Seat

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay {
                Text("\(seat.displayName) · focused").font(.callout).foregroundStyle(.tertiary)
            }
    }
}

struct TerminalTile: View {
    let seat: Seat
    let large: Bool
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @State private var bodySize = CGSize(width: 400, height: 200)
    @State private var composing = false

    private var terminals: TerminalStore { rig.terminals }
    private var focused: Bool { terminals.focusedSeatID == seat.id }
    private var prompt: PromptInstance? { rig.prompts.first { $0.seatID == seat.id } }
    private var phase: SeatPhase { prompt != nil ? .needsYou : SeatPhase(seat) }
    private var attention: Bool { phase == .needsYou }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Min sizes 0: a pane larger than the tile is clipped, never allowed to grow it.
            screen
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    bodySize = $0
                }
                .overlay {
                    // SwiftTerm's NSView takes clicks for itself; this layer catches them until Type mode. The first
                    // click focuses the tile, a second one starts typing. A real Button, for VoiceOver and keyboard.
                    if !(focused && terminals.typing) {
                        Button(action: activate) {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            focused
                                ? "Type into \(seat.displayName)'s terminal" : "Focus \(seat.displayName)'s terminal")
                    }
                }
            if let prompt {
                Divider()
                // Answer bar: a prompt can be answered from any tile without moving focus.
                PermissionControl(
                    prompt: prompt, linked: prompt.linkedQItem(in: rig.items), compact: true,
                    paneShowsPrompt: large, hint: "click to answer · keys go to the focused tile"
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.attention.opacity(0.08))
                .background(Color.tileChrome)
            }
            // A seat with a prompt can't take a message (rig send refuses until it's answered).
            if prompt == nil || focused {
                Divider()
                footer
            }
        }
        // Fill the frame the grid gives the tile, and clip to it, whatever the terminal's own size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.terminalBody)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    attention ? Color.attention : phase.isDown ? phase.color : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: attention ? 1.5 : 1, dash: phase.isDown ? [5, 3] : []))
        }
        .overlay {
            // Focus ring: separate from the attention border and from selection. Solid in both modes (dashes
            // mean a down seat); Type mode turns it accent, with "typing" in the header.
            if focused {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(terminals.typing ? Color.accentColor : .primary, lineWidth: 2)
                    .padding(-3)
            }
        }
        .onChange(of: focused) { composing = false }
    }

    private func activate() {
        if focused {
            terminals.typing = true
        } else {
            terminals.focus(seat)
            selection.select(seat: seat, in: rig)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(phase: phase)
            Button(seat.displayName) {
                if !focused { activate() }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(stateLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(phase == .idle || phase == .unknown ? Color.secondary : phase.color)
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 6)
            if focused && terminals.typing {
                Label("typing", systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
            }
            workChip
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        // Tint over the chrome, not over the black terminal body, so light mode stays light.
        .background(attention ? Color.attention.opacity(0.14) : .clear)
        .background(Color.tileChrome)
    }

    /// The seat's current qitem, or the one it is holding; "no work" otherwise.
    @ViewBuilder private var workChip: some View {
        if let (id, held) = work {
            Button {
                selection.select(qitem: id)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(held ? Color.secondary : .orange).frame(width: 6, height: 6)
                    Text(held ? "\(shortQItemID(id)) held" : shortQItemID(id))
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .overlay {
                    if selection.qitemID == id {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary, lineWidth: 1.5).padding(-2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(rig.item(id)?.summary ?? seat.currentQItems.first?.bodyExcerpt ?? id)
        } else {
            Text("no work").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var work: (QItem.ID, held: Bool)? {
        if let current = seat.currentQItems.first { return (current.id, false) }
        guard let session = seat.sessionName else { return nil }
        let held = rig.items.first { item in
            guard item.destination == session, case .blocked = workStatus(item) else { return false }
            return true
        }
        return held.map { ($0.id, true) }
    }

    private func stateLine(now: Date) -> String {
        var parts = [phase.label]
        if let prompt {
            parts.append("permission")
            if let age = compactAge(since: prompt.observedAt, now: now) { parts.append(age) }
            return parts.joined(separator: " · ")
        }
        if let age = compactAge(since: seat.activity?.since, now: now) { parts.append(age) }
        if terminals.isStale(seat, now: now) && !focused && !phase.isDown { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    // MARK: Screen

    @ViewBuilder private var screen: some View {
        if phase.isDown {
            // A dead pane's last snapshot would look live; say what happened instead.
            Text(phase == .down(.lost) ? "The tmux session is gone." : "No session running.")
                .font(.callout)
                .foregroundStyle(Color(white: 0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snap = terminals.snapshot(seat) {
            let inner = CGSize(width: bodySize.width - 24, height: bodySize.height - 12)
            // Readable first: a pane wider than the tile at 8.5 pt is clipped on the right.
            let font = TerminalSurface.fittingFontSize(cols: snap.cols, width: inner.width, range: 8.5...13)
            let fitRows = max(2, Int(inner.height / TerminalSurface.lineHeight(font)))
            Group {
                if focused, terminals.typing, let attach = terminals.attach, let size = terminals.attachSize {
                    // Type mode: the live client, sized to the tile so it is drawn whole. (Positioned partly
                    // outside its clip, SwiftTerm's view of an attached client draws nothing.)
                    TerminalSurface(
                        source: .attached(attach), cols: size.cols, rows: size.rows, fontSize: font,
                        interactive: true
                    )
                    .fixedSize()
                    .onChange(of: fitRows, initial: true) {
                        // The pane's own width: a narrower client crops the pane's right-hand columns.
                        terminals.fitAttach(GridSize(cols: snap.cols, rows: fitRows))
                    }
                } else {
                    // The tail of the agent's transcript (not Claude Code's input box), as many rows as fit;
                    // tiles never scroll. A focused tile shows this too until Type mode: snapshots refresh every
                    // second and on every seat event.
                    let rows = max(1, min(snap.rows, fitRows, snap.transcriptEnd))
                    TerminalSurface(
                        source: .snapshot(snap, lastRows: rows, transcriptOnly: true), cols: snap.cols, rows: rows,
                        fontSize: font, interactive: false
                    )
                    .fixedSize()
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else {
            Text(seat.tmuxPane == nil ? "No tmux pane bound to this seat." : "Waiting for tmux…")
                .font(.callout)
                .foregroundStyle(Color(white: 0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        Group {
            if focused {
                focusedBar
            } else if composing {
                HStack(alignment: .top, spacing: 8) {
                    MessageComposer(seat: seat, inline: true, autofocus: true) {
                        // Long enough to read "Sent", then back to one line.
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            composing = false
                        }
                    }
                    Button("Close", systemImage: "xmark") { composing = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .padding(.top, 7)
                }
            } else {
                Button {
                    composing = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        Text(messagePrompt).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(phase.isDown || seat.sessionName == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(Color.tileChrome)
    }

    /// One half of the Message / Type switch: a small neutral pill when selected, plain text otherwise.
    private func modeButton(_ title: String, typing: Bool) -> some View {
        let selected = terminals.typing == typing
        return Button(title) { terminals.typing = typing }
            .buttonStyle(.plain)
            .font(.caption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: .capsule)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var messagePrompt: String {
        if phase.isDown { return "\(seat.displayName) isn't running" }
        if phase == .working { return "Message \(seat.displayName) · delivers after this turn" }
        return "Message \(seat.displayName)"
    }

    private var focusedBar: some View {
        @Bindable var terminals = terminals
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                modeButton("Message · rig send", typing: false)
                modeButton("Type into terminal", typing: true)
            }
            .help("Message waits for a safe moment; typing sends keys straight to tmux. ⌘T switches, Esc stops typing")
            if terminals.typing {
                HStack {
                    Label("Keys go straight to tmux · Esc to stop", systemImage: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                MessageComposer(seat: seat, inline: true)
            }
        }
    }
}

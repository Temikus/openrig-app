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
    @Environment(AppStore.self) private var app
    @Environment(SelectionStore.self) private var selection
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the grid was scrolled before Type mode, to put it back afterwards.
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var gridOffset: CGFloat = 0
    @State private var offsetBeforeTyping: CGFloat = 0
    /// The order when focus began. Nothing moves while a tile has focus, except that a seat with a new
    /// prompt still gets a large tile, appended after the others.
    @State private var frozen: FrozenOrder?
    @State private var keyMonitor: Any?
    /// The pointer or VoiceOver is on a tile: freeze the order as focus does, so it doesn't move under them.
    @State private var pointerInGrid = false
    @AccessibilityFocusState private var voiceOverTile: Seat.ID?
    private var holdsOrder: Bool { pointerInGrid || voiceOverTile != nil }

    private var terminals: TerminalStore { rig.terminals }

    private enum Metrics {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 16
        /// A tile's header, footer and body padding around the terminal while typing; sizes the typing tile.
        static let typingChrome: CGFloat = 96
        static let stripHeight: CGFloat = 28
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
                        .scrollPosition($scroll)
                        #if DEBUG
                            // OPENRIG_DEBUG_SCROLL=<points> scrolls the grid down once, as a person would, to check
                            // that leaving Type mode puts it back.
                            .task {
                                guard
                                    let y = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_SCROLL"].flatMap(
                                        Double.init)
                                else { return }
                                try? await Task.sleep(for: .seconds(4))
                                scroll.scrollTo(y: y)
                            }
                        #endif
                        // In scrollTo(y:)'s terms: contentOffset counts the toolbar's inset, scrollTo doesn't.
                        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) {
                            _, y in
                            if !terminals.typing { gridOffset = y }
                        }
                        // Type mode puts the typing tile first, so show the top; leaving it, go back to where
                        // the grid was. The grid lays out again first, hence the deferred scroll.
                        .onChange(of: terminals.typing) { _, typing in
                            // Saved here: by the time typing ends, the tracker has already seen the reset to the top.
                            if typing {
                                offsetBeforeTyping = gridOffset
                                scroll.scrollTo(edge: .top)
                            } else {
                                let offset = offsetBeforeTyping
                                Task { @MainActor in scroll.scrollTo(y: offset) }
                            }
                        }
                }
                .task(id: rig.rigID) {
                    await terminals.run { rig.graph?.seats.compactMap(\.tmuxPane) ?? [] }
                }
            } else {
                ProgressView()
            }
        }
        .focusedSceneValue(\.terminalActions, terminals.tmux == nil ? nil : menuActions)
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            terminals.release()
            frozen = nil
        }
        .onChange(of: rig.prompts.map(\.seatID)) { _, seats in
            if let focused = terminals.focusedSeatID, seats.contains(focused) { terminals.pauseForPrompt(on: focused) }
        }
        .onChange(of: terminals.focusedSeatID != nil || holdsOrder) { _, hold in
            guard let graph = rig.graph else { return }
            if !hold {
                frozen = nil
            } else if frozen == nil {
                // Freeze what is on screen, filler included.
                frozen = terminals.layout ?? FrozenOrder(large: largeByState(graph), small: [])
            }
        }
    }

    private func grid(_ graph: RigGraph, viewport: CGSize) -> some View {
        let width = max(0, viewport.width - 2 * Metrics.padding)
        let (large, small, filler) = arrangement(graph, width: width)
        terminals.order = large.map(\.id) + small.compactMap { $0.isPlaceholder ? nil : $0.seat.id }
        if frozen == nil {
            terminals.layout = FrozenOrder(large: large.map(\.id), small: small.map(\.seat.id), filler: filler)
        }

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

        // Type mode: a strip of the other seats (so a new prompt elsewhere stays in sight), then the typing tile, as
        // tall as its pane needs at a readable size. Esc or ⌘T brings the grid back as it was.
        let typingSeat = terminals.typing ? graph.seats.first { $0.id == terminals.focusedSeatID } : nil

        return VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let typingSeat {
                seatStrip(graph.seats.filter { $0.id != typingSeat.id })
                    .transition(.opacity)
                TerminalTile(seat: typingSeat, large: true, voiceOverTile: $voiceOverTile)
                    .frame(
                        width: width,
                        height: typingHeight(
                            typingSeat, width: width, available: available - Metrics.stripHeight - Metrics.spacing)
                    )
                    .transition(.opacity)
            } else {
                Group {
                    tileRows(
                        large.map { Slot(seat: $0) }, cols: largeCols, width: width, height: largeHeight,
                        isLarge: true)
                    tileRows(small, cols: smallCols, width: width, height: smallHeight, isLarge: false)
                }
                .transition(.opacity)
            }
        }
        // A crossfade, not a resize: tiles host live terminals, and a frame animated step by step would refit
        // the tmux client on every step.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: terminals.typing)
        .onHover { pointerInGrid = $0 }
        // A click between tiles releases focus.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { terminals.release() })
    }

    /// Large tiles, then small slots. A lone large tile would leave half its row empty (panes are 84 columns),
    /// so the most recently active other seat fills the row. While focus is held, a focused small tile takes
    /// the filler's place, or moves up and leaves a placeholder below.
    private func arrangement(_ graph: RigGraph, width: CGFloat)
        -> (large: [Seat], small: [Slot], filler: Seat.ID?)
    {
        let seat = { (id: Seat.ID) in graph.seats.first { $0.id == id } }
        guard let frozen else {
            var large = largeByState(graph)
            var filler: Seat.ID?
            if large.count == 1, width >= 2 * Metrics.largeMinWidth + Metrics.spacing {
                filler = mostRecentlyActive(graph.seats.filter { !large.contains($0.id) && !SeatPhase($0).isDown })
                if let filler { large.append(filler) }
            }
            let small = graph.seats.filter { !large.contains($0.id) }.map { Slot(seat: $0) }
            return (large.compactMap(seat), small, filler)
        }
        var largeIDs = frozen.large.filter { seat($0) != nil }
        var smallIDs = frozen.small
        for prompt in rig.prompts where !largeIDs.contains(prompt.seatID) { largeIDs.append(prompt.seatID) }
        if let focused = terminals.focusedSeatID, !largeIDs.contains(focused) {
            if let filler = frozen.filler, let at = largeIDs.firstIndex(of: filler),
                let slot = smallIDs.firstIndex(of: focused)
            {
                // Swap: the focused seat takes the filler's large slot, the filler its small one.
                largeIDs[at] = focused
                smallIDs[slot] = filler
            } else {
                largeIDs.append(focused)
            }
        }
        var small = smallIDs.compactMap(seat).map { Slot(seat: $0, isPlaceholder: largeIDs.contains($0.id)) }
        let known = Set(frozen.large + frozen.small)
        small += graph.seats.filter { !known.contains($0.id) && !largeIDs.contains($0.id) }.map { Slot(seat: $0) }
        return (largeIDs.compactMap(seat), small, frozen.filler)
    }

    /// The typing tile's height: its whole pane at the width-fit size when that fits, else everything available.
    private func typingHeight(_ seat: Seat, width: CGFloat, available: CGFloat) -> CGFloat {
        let room = max(Metrics.largeMinHeight, available)
        guard let snap = terminals.snapshot(seat) else { return room }
        let font = TerminalSurface.fittingFontSize(
            cols: snap.cols, width: width - 24, scale: displayScale,
            range: CGFloat(app.settings.smallestTileText)...13)
        let needed = CGFloat(snap.rows + snap.statusRows) * TerminalSurface.lineHeight(font) + Metrics.typingChrome
        return min(room, max(Metrics.largeMinHeight, needed))
    }

    /// The other seats while typing: a status dot and name each, coral when one needs you. Clicking one leaves Type
    /// mode and focuses that seat, where its answer bar is.
    private func seatStrip(_ seats: [Seat]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(seats) { seat in
                    let prompted = rig.prompts.contains { $0.seatID == seat.id }
                    let phase = prompted ? SeatPhase.needsYou : SeatPhase(seat)
                    Button {
                        terminals.focus(seat)
                        selection.select(seat: seat, in: rig)
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(phase: phase)
                            Text(seat.displayName).lineLimit(1)
                            if prompted { Text("needs you").foregroundStyle(Color.attention) }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: Metrics.stripHeight - 4)
                        .background(
                            prompted ? Color.attention.opacity(0.14) : Color.primary.opacity(0.06), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help(
                        prompted
                            ? "\(seat.displayName) is asking for permission: open its tile"
                            : "Focus \(seat.displayName)")
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: Metrics.stripHeight)
    }

    private func mostRecentlyActive(_ seats: [Seat]) -> Seat.ID? {
        seats.max { ($0.activity?.since ?? .distantPast) < ($1.activity?.since ?? .distantPast) }?.id
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
                            TerminalTile(seat: slot.seat, large: isLarge, voiceOverTile: $voiceOverTile)
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

    /// The view's own keys; `terminalKeyAction` decides what each one does. Keys that reach a popover or a
    /// sheet (their own windows; never the main window) pass through, so Esc still closes them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let terminals = self.terminals
        let rig = self.rig
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            let key: TerminalKey? =
                switch (event.keyCode, command) {
                case (53, false): .escape
                case (30, true): .nextTile
                case (33, true): .previousTile
                case (17, true): .toggleTyping
                default: nil
                }
            guard let key else { return event }
            let context = TerminalKeyContext(
                inMainWindow: event.window != nil && event.window === NSApp.mainWindow,
                focused: terminals.focusedSeatID != nil, typing: terminals.typing,
                editingText: event.window?.firstResponder is NSText, escGoesToPane: app.settings.escGoesToPane)
            switch terminalKeyAction(key, context) {
            case .passThrough:
                return event
            case .stopTyping:
                terminals.typing = false
            case .releaseFocus:
                terminals.release()
            case .toggleTyping:
                terminals.typing.toggle()
            case .moveFocus(let step):
                guard !terminals.order.isEmpty else { return event }
                Self.moveFocus(step, terminals: terminals, rig: rig)
            }
            return nil
        }
    }

    /// ⌘] and ⌘[: the next or previous tile in display order, wrapping.
    private static func moveFocus(_ step: Int, terminals: TerminalStore, rig: RigStore) {
        let order = terminals.order
        guard !order.isEmpty else { return }
        let current = terminals.focusedSeatID.flatMap { order.firstIndex(of: $0) }
        let next = current.map { ($0 + step + order.count) % order.count } ?? (step > 0 ? 0 : order.count - 1)
        if let seat = rig.seat(order[next]) { terminals.focus(seat) }
    }

    private var menuActions: TerminalActions {
        let terminals = self.terminals
        let rig = self.rig
        return TerminalActions(
            next: { Self.moveFocus(1, terminals: terminals, rig: rig) },
            previous: { Self.moveFocus(-1, terminals: terminals, rig: rig) },
            toggleTyping: terminals.focusedSeatID == nil ? nil : { terminals.typing.toggle() },
            typing: terminals.typing)
    }

}

struct FrozenOrder: Equatable {
    var large: [Seat.ID]
    var small: [Seat.ID]
    /// An idle seat shown large only so a lone large tile has a neighbour.
    var filler: Seat.ID?
}

private struct Slot {
    var seat: Seat
    var isPlaceholder = false
}

/// Holds a small tile's place while its seat is focused in the large row, so nothing below moves.
private struct PlaceholderTile: View {
    let seat: Seat

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay {
                Text("\(seat.displayName) · focused").font(.callout).foregroundStyle(.secondary)
            }
    }
}

struct TerminalTile: View {
    let seat: Seat
    let large: Bool
    var voiceOverTile: AccessibilityFocusState<Seat.ID?>.Binding
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @Environment(AppStore.self) private var app
    @State private var bodySize = CGSize.zero
    @Environment(\.displayScale) private var displayScale
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
                .overlay(alignment: .trailing) {
                    if clipsRight {
                        LinearGradient(
                            colors: [Color.terminalBody.opacity(0), .terminalBody], startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 28)
                        .allowsHitTesting(false)
                    }
                }
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
                                ? "Type into \(seat.displayName)'s terminal" : "Focus \(seat.displayName)'s terminal"
                        )
                        .accessibilityValue(terminals.snapshot(seat)?.text(lastRows: 12, transcriptOnly: true) ?? "")
                        .accessibilityFocused(voiceOverTile, equals: seat.id)
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
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    attention ? Color.attention : phase.isDown ? phase.color : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: attention ? 1.5 : 1, dash: phase.isDown ? [5, 3] : []))
        }
        .overlay {
            // Focus ring: separate from the attention border and from selection. Solid in both modes (dashes
            // mean a down seat); Type mode turns it accent, with "typing" in the header.
            if focused {
                RoundedRectangle(cornerRadius: 13)
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
            // Settings › Terminals › Start typing on focus, except on a prompt: Enter there would answer it.
            if app.settings.typeOnFocus, !rig.prompts.contains(where: { $0.seatID == seat.id }) {
                terminals.typing = true
            }
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
                Label(
                    terminals.panned > 0 ? "typing · \(terminals.panned) rows above" : "typing",
                    systemImage: "keyboard"
                )
                .font(.caption).foregroundStyle(.secondary)
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
            Text("no work").font(.caption).foregroundStyle(.secondary)
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

    /// Whether the pane is wider than the tile at the smallest tile text, so its right edge is cut off. Type mode
    /// uses the same width-fit size whenever the whole pane doesn't fit, so this holds there too.
    private var clipsRight: Bool {
        guard !phase.isDown, let snap = terminals.snapshot(seat), bodySize.width > 0 else { return false }
        let width = bodySize.width - 24
        let font = TerminalSurface.fittingFontSize(
            cols: snap.cols, width: width, scale: displayScale, range: CGFloat(app.settings.smallestTileText)...13)
        return CGFloat(snap.cols) * TerminalSurface.advance(font, scale: displayScale) > width + 0.5
    }

    @ViewBuilder private var screen: some View {
        if phase.isDown {
            // A dead pane's last snapshot would look live; say what happened instead.
            Text(phase == .down(.lost) ? "The tmux session is gone." : "No session running.")
                .font(.callout)
                .foregroundStyle(Color(white: 0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snap = terminals.snapshot(seat) {
            let inner = CGSize(width: bodySize.width - 24, height: bodySize.height - 12)
            // Readable first: a pane wider than the tile at the smallest size (Settings › Terminals) is clipped on
            // the right.
            let floor = CGFloat(app.settings.smallestTileText)
            let font = TerminalSurface.fittingFontSize(
                cols: snap.cols, width: inner.width, scale: displayScale, range: floor...13)
            let fitRows = max(2, Int(inner.height / TerminalSurface.lineHeight(font)))
            Group {
                if focused, terminals.typing, let attach = terminals.attach, let size = terminals.attachSize {
                    // Type mode: the live client. The whole pane when it fits at the smallest tile text or larger;
                    // otherwise the width-fit size and the rows that fit, panned to where the person types (tmux
                    // shows the top of a taller pane, and Claude Code hides the cursor tmux would follow). The view
                    // never outgrows its clip: SwiftTerm draws nothing then.
                    let paneRows = snap.rows + snap.statusRows
                    let floor = CGFloat(app.settings.smallestTileText)
                    let whole = TerminalSurface.fittingFontSize(
                        cols: snap.cols, rows: paneRows, width: inner.width, height: inner.height, scale: displayScale,
                        range: floor...13)
                    let fitsWhole = TerminalSurface.fits(
                        cols: snap.cols, rows: paneRows, size: whole, width: inner.width, height: inner.height,
                        scale: displayScale)
                    let typeFont =
                        fitsWhole
                        ? whole
                        : TerminalSurface.fittingFontSize(
                            cols: snap.cols, width: inner.width, scale: displayScale, range: floor...13)
                    let shown = fitsWhole ? paneRows : max(2, Int(inner.height / TerminalSurface.lineHeight(typeFont)))
                    let target = GridSize(cols: snap.cols, rows: shown)
                    let offset = snap.panOffset(clientRows: shown - snap.statusRows)
                    TerminalSurface(
                        source: .attached(attach), cols: size.cols, rows: size.rows, fontSize: typeFont,
                        interactive: true, optionAsMeta: app.settings.optionAsMeta, accessibleText: snap.text(),
                        accessibleName: seat.displayName, onRepaint: { terminals.repaint() }
                    )
                    .fixedSize()
                    .onChange(of: target, initial: true) { if inner.width > 0 { terminals.fitAttach(target) } }
                    .onChange(of: offset, initial: true) { terminals.pan(offset) }
                    // The daemon reports prompts every few seconds; the pane shows one within a second. Either way
                    // typing stops before Enter could answer it.
                    .onChange(of: PromptScreen(lines: snap.lines) != nil) { _, prompted in
                        // Only as a prompt appears: ⌘T after that is a deliberate choice to answer in the pane.
                        if prompted { terminals.pauseForPrompt(on: seat.id) }
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
        let stop = app.settings.escGoesToPane ? "⌘T to stop · Esc goes to the pane" : "Esc or ⌘T to stop"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                modeButton("Message · rig send", typing: false)
                modeButton("Type into terminal", typing: true)
                if terminals.typing {
                    Spacer(minLength: 12)
                    Label("Keys go to \(seat.displayName) · \(stop)", systemImage: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Done") { terminals.typing = false }
                        .controlSize(.small)
                        .padding(.leading, 8)
                        .help("Stop typing and show every tile")
                }
            }
            .padding(.leading, -9)
            .help("Message waits for a safe moment; typing sends keys straight to the pane. ⌘T switches")
            if terminals.pausedForPrompt == seat.id {
                Label(
                    "Typing paused: \(seat.displayName) is asking for permission. Answer it, then ⌘T to type again.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Color.attention)
            }
            if !terminals.typing {
                MessageComposer(seat: seat, inline: true)
            }
        }
    }
}

import AppKit
import RigDomain
import RigModel
import RigTerminal
import SwiftUI

/// Every seat's terminal as a tile. Snapshots refresh every second; the focused tile is a live tmux client.
struct TerminalsView: View {
    @Environment(RigStore.self) private var rig
    @State private var largeWhileFocused: Set<Seat.ID>?
    @State private var escMonitor: Any?

    private var terminals: TerminalStore { rig.terminals }

    var body: some View {
        Group {
            if terminals.tmux == nil {
                ContentUnavailableView(
                    "tmux not found", systemImage: "terminal",
                    description: Text("Install tmux (brew install tmux) to see seat terminals."))
            } else if let graph = rig.graph {
                let large = largeSeats(graph)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        tileGrid(graph.seats.filter { large.contains($0.id) }, large: true, minWidth: 460)
                        tileGrid(graph.seats.filter { !large.contains($0.id) }, large: false, minWidth: 300)
                    }
                    .padding(16)
                }
                .task(id: rig.rigID) {
                    await terminals.run { rig.graph?.seats.compactMap(\.tmuxPane) ?? [] }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: installEscMonitor)
        .onDisappear {
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
            terminals.release()
            largeWhileFocused = nil
        }
        .onChange(of: terminals.focusedSeatID) { _, focused in
            // Tiles never regroup while one has focus.
            largeWhileFocused = focused == nil ? nil : (largeWhileFocused ?? rig.graph.map(largeByState))
        }
    }

    @ViewBuilder private func tileGrid(_ seats: [Seat], large: Bool, minWidth: CGFloat) -> some View {
        if !seats.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(seats) { TerminalTile(seat: $0, large: large) }
            }
        }
    }

    private func largeSeats(_ graph: RigGraph) -> Set<Seat.ID> {
        var set = largeWhileFocused ?? largeByState(graph)
        if let focused = terminals.focusedSeatID { set.insert(focused) }
        return set
    }

    /// Seats that are working or need you get large tiles; idle ones get short tail tiles.
    private func largeByState(_ graph: RigGraph) -> Set<Seat.ID> {
        Set(graph.seats.filter { [.working, .needsYou].contains(SeatPhase($0)) }.map(\.id))
    }

    /// Esc leaves Type mode instead of reaching the agent, so a stray Esc never interrupts a turn.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        let terminals = self.terminals
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, terminals.typing else { return event }
            terminals.typing = false
            return nil
        }
    }
}

struct TerminalTile: View {
    let seat: Seat
    let large: Bool
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection
    @State private var width: CGFloat = 400

    private var terminals: TerminalStore { rig.terminals }
    private var focused: Bool { terminals.focusedSeatID == seat.id }
    private var phase: SeatPhase { SeatPhase(seat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            screen
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(white: 0.08))
                .overlay {
                    // SwiftTerm's NSView takes clicks for itself; this layer catches them until the tile has focus.
                    // A real Button, so VoiceOver and the keyboard can focus a tile too.
                    if !focused {
                        Button {
                            terminals.focus(seat)
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Focus \(seat.displayName)'s terminal")
                    }
                }
            if focused { typeBar }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    phase == .needsYou ? Color.red : Color(nsColor: .separatorColor),
                    lineWidth: phase == .needsYou ? 2 : 1)
        }
        .overlay {
            // Focus ring: separate from the attention border and from selection.
            if focused {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(
                        Color.primary, style: StrokeStyle(lineWidth: 2, dash: terminals.typing ? [6, 4] : [])
                    )
                    .padding(-3)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(phase: phase)
            Button(seat.displayName) { selection.select(seat: seat, in: rig) }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(stateLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(phase == .needsYou ? Color.red : .secondary)
            }
            Spacer()
            if let item = seat.currentQItems.first {
                Button(shortQItemID(item.id)) { selection.select(qitem: item.id) }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.25), in: .rect(cornerRadius: 4))
                    .overlay {
                        if selection.qitemID == item.id {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 1.5).padding(-2)
                        }
                    }
                    .help(item.bodyExcerpt)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background)
        .overlay {
            if selection.seatID == seat.id {
                Rectangle().frame(height: 2).foregroundStyle(Color.accentColor).frame(
                    maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func stateLine(now: Date) -> String {
        var parts = [phase.label]
        if let age = compactAge(since: seat.activity?.since, now: now) { parts.append(age) }
        if terminals.isStale(seat, now: now) && !focused { parts.append("stale") }
        if focused { parts.append("live") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var screen: some View {
        if let snap = terminals.snapshot(seat) {
            // Small tiles show the pane's last 8 rows; large ones up to 30; the focused one all of it.
            let attachRows = snap.rows + snap.statusRows
            let shownRows = focused ? attachRows : min(snap.rows, large ? 30 : 8)
            // The focused tile shows the whole pane, so it also fits a height that leaves room for the others.
            let font = TerminalSurface.fittingFontSize(
                cols: snap.cols, rows: focused ? shownRows : 0, width: width - 16, height: focused ? 460 : .infinity)
            if focused, let attach = terminals.attach {
                TerminalSurface(
                    source: .attached(attach), cols: snap.cols, rows: shownRows, fontSize: font,
                    interactive: terminals.typing
                )
                .fixedSize()
                .padding(2)
            } else {
                TerminalSurface(
                    source: .snapshot(snap, lastRows: shownRows), cols: snap.cols, rows: shownRows, fontSize: font,
                    interactive: false
                )
                .fixedSize()
                .padding(2)
                .allowsHitTesting(false)
            }
        } else {
            Text(seat.tmuxPane == nil ? "No tmux pane bound to this seat." : "Waiting for tmux…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var typeBar: some View {
        HStack(spacing: 10) {
            if terminals.typing {
                Label("Keys go straight to tmux · Esc to stop", systemImage: "keyboard")
                    .font(.caption)
                Spacer()
                Button("Stop typing") { terminals.typing = false }
                    .controlSize(.small)
            } else {
                // Message mode: the composer sends through `rig send`, which waits for a safe moment.
                MessageComposer(seat: seat)
                Button("Type into terminal") { terminals.typing = true }
                    .controlSize(.small)
                    .help("Keys go straight to tmux until Esc")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background)
    }
}

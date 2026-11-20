import RigClient
import RigDomain
import RigModel
import SwiftUI

/// The outcome of the last command a control ran: spinner, a short success line, or the CLI's error.
struct ActionStatusLine: View {
    let key: String
    @Environment(ActionStore.self) private var actions

    var body: some View {
        switch actions.status[key] {
        case .running?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .succeeded(let text)?:
            Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let text)?:
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.attention)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }
}

/// A commit button named for what it does ("Hand off to orch-lead"), disabled until the form is complete.
/// Hovering shows the exact `rig` command.
struct CommitButton: View {
    let title: String
    let action: RigAction?
    let key: String
    var success = "Done"
    var after: () -> Void = {}
    @Environment(ActionStore.self) private var actions

    var body: some View {
        Button(title) {
            guard let action else { return }
            Task {
                if await actions.perform(action, key: key, success: success) {
                    actions.clearDrafts(for: key)
                    after()
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(action == nil || actions.isRunning(key) || actions.offline)
        .keyboardShortcut(.return, modifiers: .command)
        .help(action?.displayCommand ?? "Fill in the required fields")
    }
}

extension View {
    /// Keeps `text` in `ActionStore.drafts` under "<key>|<field>": restored when the view comes back, so closing a
    /// popover, panel or tile doesn't throw away what was typed.
    func keepsDraft(_ text: Binding<String>, _ key: String, _ field: String) -> some View {
        modifier(KeepsDraft(text: text, key: "\(key)|\(field)"))
    }
}

private struct KeepsDraft: ViewModifier {
    @Binding var text: String
    let key: String
    @Environment(ActionStore.self) private var actions

    func body(content: Content) -> some View {
        content
            .onAppear { if text.isEmpty, let draft = actions.drafts[key] { text = draft } }
            .onChange(of: text) { actions.drafts[key] = text.isEmpty ? nil : text }
    }
}

// MARK: - Message composer (rig send)

struct MessageComposer: View {
    let seat: Seat
    /// Terminal tiles: a bordered field with the send button inside it and no caption. The inspector keeps
    /// the standard field.
    var inline = false
    /// Put the cursor in the field on appear: only when the user just asked for it (opened a tile's footer),
    /// never because a tile gained focus.
    var autofocus = false
    var onSent: () -> Void = {}
    @Environment(ActionStore.self) private var actions
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var key: String { "send:\(seat.id)" }
    /// No session to type into; `rig send` would fail.
    private var isDown: Bool { SeatPhase(seat).isDown }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if inline {
                HStack(alignment: .bottom, spacing: 6) {
                    field.textFieldStyle(.plain).lineLimit(1...3)
                    sendButton.font(.title3)
                }
                .padding(.leading, 10)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .onAppear { if autofocus { fieldFocused = true } }
                ActionStatusLine(key: key)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    field.textFieldStyle(.roundedBorder).lineLimit(1...5)
                    sendButton.font(.title2)
                }
                HStack {
                    Text("rig send · ⌘↩").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    ActionStatusLine(key: key)
                }
            }
        }
    }

    private var field: some View {
        TextField(
            isDown ? "\(seat.displayName) isn't running" : "Message \(seat.displayName)…", text: $text, axis: .vertical
        )
        .focused($fieldFocused)
        .disabled(isDown)
        .keepsDraft($text, key, "text")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEmpty || seat.sessionName == nil || isDown)
            .help(action.map(\.displayCommand) ?? "")
    }

    private var action: RigAction? {
        seat.sessionName.map { RigAction.send(session: $0, text: text) }
    }

    private func send() {
        guard let action else { return }
        Task {
            if await actions.perform(action, key: key, success: "Sent") {
                text = ""
                onSent()
            }
        }
    }
}

// MARK: - Queue task (rig queue create)

struct QueueTaskForm: View {
    let rig: RigStore
    var preselected: String?
    var done: () -> Void
    @State private var destination: String?
    @State private var summary = ""
    @State private var detail = ""
    @State private var priority = Priority.routine

    private var key: String { "create:\(rig.rigName)" }

    var body: some View {
        Form {
            Picker("For", selection: $destination) {
                Text("Choose a seat").tag(String?.none)
                ForEach(rig.graph?.seats ?? []) { seat in
                    if let session = seat.sessionName { Text(seat.displayName).tag(String?.some(session)) }
                }
            }
            TextField("Summary", text: $summary, prompt: Text("One line the owner and the board will show"))
                .keepsDraft($summary, key, "summary")
            TextField("Details", text: $detail, prompt: Text("Optional; the summary is used if empty"), axis: .vertical)
                .lineLimit(3...8)
                .keepsDraft($detail, key, "detail")
            Picker("Priority", selection: $priority) {
                ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                // Held open a second on success: closing at once took the "Queued" line with it.
                CommitButton(
                    title: "Queue for \(destination.map(rig.displayName(session:)) ?? "…")", action: action, key: key,
                    success: "Queued",
                    after: {
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            done()
                        }
                    })
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { destination = destination ?? preselected }
    }

    private var action: RigAction? {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination, !s.isEmpty else { return nil }
        return .create(destination: destination, summary: s, body: detail, priority: priority)
    }
}

// MARK: - Qitem actions, rendered in place under the action row

enum ActionPanel: String, Identifiable {
    case resolve = "Resolve"
    case handOff = "Hand off", block = "Block on", close = "Close", nudge = "Nudge", note = "Note"
    case deadline = "New deadline"
    var id: Self { self }

    /// The panel's ActionStore key prefix, as each panel builds it ("handoff:<id>").
    var keyPrefix: String {
        switch self {
        case .resolve: "resolve"
        case .handOff: "handoff"
        case .block: "block"
        case .close: "close"
        case .nudge: "nudge"
        case .note: "note"
        case .deadline: "deadline"
        }
    }
}

struct QItemActions: View {
    let item: QItem
    @Environment(RigStore.self) private var rig
    @State private var panel: ActionPanel?
    /// The panel that last closed on success: its result line shows here, since the panel took its own with it.
    @State private var finished: ActionPanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isForYou {
                // The answer panel above is the main action; these stay reachable without competing with it.
                Menu("More") {
                    ForEach(panels) { p in Button(p.rawValue) { panel = p } }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(panels) { p in
                        Button(p.rawValue) { panel = panel == p ? nil : p }
                            .buttonStyle(.bordered)
                            .tint(panel == p ? .accentColor : nil)
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
            }
            if let panel {
                Group {
                    switch panel {
                    case .resolve: ResolvePanel(item: item) { close(panel) }
                    case .handOff: HandOffPanel(item: item) { close(panel) }
                    case .block: BlockPanel(item: item) { close(panel) }
                    case .close: ClosePanel(item: item) { close(panel) }
                    case .nudge: NudgePanel(item: item) { close(panel) }
                    case .note: NotePanel(item: item) { close(panel) }
                    case .deadline: DeadlinePanel(item: item) { close(panel) }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            } else if let finished {
                ActionStatusLine(key: "\(finished.keyPrefix):\(item.id)")
            }
        }
        .onChange(of: item.id) {
            panel = nil
            finished = nil
        }
        .onChange(of: panel) { if panel != nil { finished = nil } }
    }

    private func close(_ done: ActionPanel) {
        finished = done
        panel = nil
    }

    private var isForYou: Bool { forYou(item, me: rig.me) != nil }

    private var panels: [ActionPanel] {
        var list: [ActionPanel] = [.handOff, .block, .close, .nudge, .note]
        // A row addressed to the person: nudging would message themselves, and Close would skip telling the asker.
        if isForYou { list.removeAll { $0 == .nudge || $0 == .close } }
        if case .blocked(on: .outside) = workStatus(item) { list.insert(.resolve, at: 0) }
        if isOverdue(item, now: .now) { list.append(.deadline) }
        return list
    }
}

/// Shown when the owner is mid-turn: what the action does to them right now.
struct MidTurnWarning: View {
    let item: QItem
    let text: String
    @Environment(RigStore.self) private var rig

    var body: some View {
        if let owner = rig.seat(session: item.destination), SeatPhase(owner) == .working {
            Label("\(owner.displayName) is mid-turn. \(text)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

struct HandOffPanel: View {
    let item: QItem
    let done: () -> Void
    @Environment(RigStore.self) private var rig
    @Environment(ActionStore.self) private var actions
    @State private var target: String?
    @State private var summary = ""
    @State private var detail = ""
    @State private var alsoTell = ""

    private var key: String { "handoff:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("To", selection: $target) {
                Text("Choose a seat").tag(String?.none)
                ForEach(candidates, id: \.session) { c in
                    Text(c.allowed ? c.name : "\(c.name) (no delegates_to edge)")
                        .tag(String?.some(c.session))
                        .selectionDisabled(!c.allowed)
                }
            }
            TextField("Summary for the new owner", text: $summary).keepsDraft($summary, key, "summary")
            TextField("Details (optional)", text: $detail, axis: .vertical).lineLimit(2...6)
                .keepsDraft($detail, key, "detail")
            TextField("Also tell them (optional rig send)", text: $alsoTell).keepsDraft($alsoTell, key, "tell")
            MidTurnWarning(item: item, text: "Their row closes now; they see the handoff after this turn.")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Hand off to \(target.map(rig.displayName(session:)) ?? "…")", action: action, key: key,
                    success: "Handed off"
                ) {
                    let message = alsoTell.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let target, !message.isEmpty {
                        Task {
                            await actions.perform(
                                .send(session: target, text: message), key: key, success: "Handed off and told")
                        }
                    }
                    done()
                }
            }
        }
        .onAppear { if summary.isEmpty { summary = item.summary } }
    }

    /// Every seat but the owner. Only seats the owner `delegates_to` in the spec can take a handoff.
    private var candidates: [(session: String, name: String, allowed: Bool)] {
        guard let graph = rig.graph else { return [] }
        let owner = rig.seat(session: item.destination)?.id
        let allowed = Set(graph.edges.filter { $0.source == owner && $0.kind == .delegatesTo }.map(\.target))
        return graph.seats.compactMap { seat in
            guard let session = seat.sessionName, session != item.destination else { return nil }
            return (session, seat.displayName, allowed.contains(seat.id))
        }
    }

    private var action: RigAction? {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !s.isEmpty else { return nil }
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return .handoff(id: item.id, to: target, summary: s, body: d.isEmpty ? nil : d)
    }
}

struct BlockPanel: View {
    let item: QItem
    let done: () -> Void
    @Environment(RigStore.self) private var rig
    @State private var blocker = ""
    @State private var wakeAfter = "1h"
    @State private var summary = ""

    private var key: String { "block:\(item.id)" }
    private var onPerson: Bool { !blocker.isEmpty && !blocker.hasPrefix("qitem-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(
                    "Blocked on", text: $blocker, prompt: Text("qitem id, or external:… for a person or outside event"))
                Menu("Pick") {
                    ForEach(rig.items.filter { workStatus($0).isActive && $0.id != item.id }.prefix(20)) { other in
                        Button("\(shortQItemID(other.id)) · \(other.summary)") { blocker = other.id }
                    }
                }
                .fixedSize()
            }
            Picker("Wake after", selection: $wakeAfter) {
                ForEach(["15m", "1h", "4h", "1d"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            if onPerson {
                TextField("What decision is owed (required)", text: $summary).keepsDraft($summary, key, "summary")
            }
            MidTurnWarning(item: item, text: "Their row parks now; they see it after this turn.")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title:
                        "Block on \(blocker.hasPrefix("qitem-") ? shortQItemID(blocker) : (blocker.isEmpty ? "…" : blocker))",
                    action: action, key: key, success: "Blocked", after: done)
            }
        }
    }

    private var action: RigAction? {
        let b = blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !onPerson || !s.isEmpty else { return nil }
        return .block(id: item.id, on: b, wakeAfter: wakeAfter, note: s.isEmpty ? nil : s)
    }
}

struct ClosePanel: View {
    let item: QItem
    let done: () -> Void
    @Environment(RigStore.self) private var rig
    @State private var reason = CloseReason.noFollowOn
    @State private var target = ""
    @State private var resolution = ""

    private var key: String { "close:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Reason", selection: $reason) {
                ForEach(CloseReason.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if reason == .superseded {
                Picker("Replaced by", selection: $target) {
                    Text("Choose a qitem").tag("")
                    ForEach(rig.items.filter { workStatus($0).isActive && $0.id != item.id }.prefix(30)) { other in
                        Text("\(shortQItemID(other.id)) · \(other.summary)").tag(other.id)
                    }
                }
            } else if reason == .escalation {
                Picker("Escalated to", selection: $target) {
                    Text("Choose a seat").tag("")
                    ForEach(rig.graph?.seats ?? []) { seat in
                        if let s = seat.sessionName { Text(seat.displayName).tag(s) }
                    }
                }
            }
            TextField("Resolution (shown on the row)", text: $resolution).keepsDraft($resolution, key, "resolution")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Close \(shortQItemID(item.id))", action: action, key: key, success: "Closed", after: done)
            }
        }
        .onChange(of: reason) { target = "" }
    }

    private var action: RigAction? {
        if reason.needsTarget && target.isEmpty { return nil }
        let r = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        return .close(
            id: item.id, reason: reason, target: reason.needsTarget ? target : nil, resolution: r.isEmpty ? nil : r)
    }
}

struct NudgePanel: View {
    let item: QItem
    let done: () -> Void
    @Environment(RigStore.self) private var rig
    @State private var text = ""

    private var key: String { "nudge:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical).lineLimit(2...5).keepsDraft($text, key, "text")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Nudge \(rig.displayName(session: item.destination))",
                    action: text.isEmpty ? nil : .send(session: item.destination, text: text), key: key,
                    success: "Nudged",
                    after: done)
            }
        }
        .onAppear {
            if text.isEmpty { text = "Checking in on \(item.id) (\(item.summary)). Where is it at?" }
        }
    }
}

/// Answers a row parked on a person or a typed gate (`external:`, `auth:`…): records the decision,
/// moves the row back to in progress and nudges its owner.
struct ResolvePanel: View {
    let item: QItem
    let done: () -> Void
    @State private var decision = ""

    private var key: String { "resolve:\(item.id)" }
    private var trimmed: String { decision.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let on = item.blockedOn {
                Text("Blocked on \(on)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Your decision", text: $decision, axis: .vertical).lineLimit(2...5)
                .keepsDraft($decision, key, "decision")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Resolve and Unblock",
                    action: trimmed.isEmpty ? nil : .resolve(id: item.id, decision: trimmed),
                    key: key, success: "Resolved", after: done)
            }
        }
    }
}

struct NotePanel: View {
    let item: QItem
    let done: () -> Void
    @State private var text = ""

    private var key: String { "note:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Note for the audit log", text: $text, axis: .vertical).lineLimit(2...5)
                .keepsDraft($text, key, "text")
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Add note", action: text.isEmpty ? nil : .note(id: item.id, text: text), key: key,
                    success: "Noted", after: done)
            }
        }
    }
}

struct DeadlinePanel: View {
    let item: QItem
    let done: () -> Void
    @State private var at = Date.now.addingTimeInterval(3600)

    private var key: String { "deadline:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Close by", selection: $at, in: Date.now...)
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                CommitButton(
                    title: "Set new deadline", action: .newDeadline(id: item.id, at: at), key: key,
                    success: "Deadline moved",
                    after: done)
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

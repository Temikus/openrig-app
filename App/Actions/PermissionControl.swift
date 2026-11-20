import RigClient
import RigDomain
import RigModel
import RigTerminal
import SwiftUI

/// The one permission control (Allow once · No, redirect… · ⌄), used on the canvas node, the Needs-you
/// strip and popover, and the terminal answer bar. It answers only the prompt it was drawn for.
struct PermissionControl: View {
    let prompt: PromptInstance
    let linked: QItem?
    var compact = false
    /// The pane on screen already shows the prompt (a large terminal tile), so the command box is left out.
    var paneShowsPrompt = false
    /// A trailing hint beside the buttons, e.g. on terminal tiles.
    var hint: String?
    @Environment(RigStore.self) private var rig
    @Environment(ActionStore.self) private var actions
    @Environment(AppStore.self) private var app
    @State private var redirecting = false
    @State private var reason = ""
    @State private var changed = false
    /// What the pane shows. Answers are only sent when this was read and still matches.
    @State private var screen: PromptScreen?

    private var key: String { "prompt:\(prompt.seatID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !(paneShowsPrompt && screen != nil) {
                if let screen {
                    Text(screen.description.map { "\(screen.title): \($0)" } ?? screen.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("wants to run").font(.caption).foregroundStyle(.secondary)
                }
                // Never truncated: the risky part of a command is often at the end. A tinted block, not a
                // bordered one, so it doesn't read as a text field.
                Text(screen?.command ?? prompt.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: compact ? 640 : .infinity, alignment: .leading)
                    .background(Color.attention.opacity(0.08), in: .rect(cornerRadius: 6))
            }

            if changed {
                HStack {
                    Label("Prompt changed", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Button("View terminal") { viewTerminal() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            } else if redirecting {
                Text("Tell \(rig.seat(prompt.seatID)?.displayName ?? "the seat") what to do instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Optional; leave empty to just decline", text: $reason, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(redirect)
                HStack(spacing: 6) {
                    Button(
                        reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Decline" : "Send instead",
                        action: redirect
                    )
                    .buttonStyle(PillButtonStyle(kind: .danger))
                    .disabled(actions.isRunning(key) || screen?.declineKey == nil)
                    Button("Back") { redirecting = false }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                }
            } else {
                HStack(spacing: 6) {
                    Button("Allow once", action: allowOnce)
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(actions.isRunning(key) || actions.offline || screen?.allowOnceKey == nil)
                        .help(
                            screen?.allowOnceKey == nil
                                ? "Can't read a plain Yes on screen; answer in the terminal" : "")
                    Button("No, redirect…") { redirecting = true }
                        .buttonStyle(PillButtonStyle(kind: .attention))
                        .disabled(actions.isRunning(key))
                    Menu {
                        Button("View terminal") { viewTerminal() }
                        // The prompt's own "don't ask again" option; Claude Code saves the rule. Its exact wording
                        // is the label, so the user sees what scope they're granting.
                        Button(screen?.rememberLabel ?? "Always allow…", action: remember)
                            .disabled(screen?.rememberOption == nil || actions.offline || actions.isRunning(key))
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: .circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More answers")
                    if let hint {
                        Spacer(minLength: 8)
                        // When the pane can't be read, say why Allow once is off instead of inviting a click.
                        Text(screen?.allowOnceKey == nil ? "can't read the prompt · answer in the terminal" : hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ActionStatusLine(key: key)
        }
        // The buttons are the same on every prompt; the group says whose prompt they answer.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rig.seat(prompt.seatID)?.displayName ?? "A seat") asks to run \(prompt.command)")
        .task(id: prompt) {
            changed = false
            redirecting = false
            screen = await rig.promptScreen(for: prompt.seatID)
        }
    }

    /// Re-reads the seat's prompt right before sending; answers only if it is still this one.
    /// Re-reads the daemon's prompt and the pane right before sending; answers only if both
    /// still show the prompt the user is looking at.
    private func stillThePrompt() async -> Bool {
        let check = prompt.check(against: await rig.currentStop(session: prompt.session))
        let fresh = await rig.promptScreen(for: prompt.seatID)
        let same = check == .same && fresh?.command == screen?.command && fresh?.options == screen?.options
        if !same {
            changed = true
            actions.clear(key)
        }
        return same
    }

    private func allowOnce() {
        Task {
            guard await stillThePrompt(), let yes = screen?.allowOnceKey else { return }
            let command = screen?.command ?? prompt.command
            let ok = await actions.perform(
                .answerPrompt(session: prompt.session, keys: yes, reason: "OpenRig.app: allow once \(command)"),
                key: key, success: "Allowed once")
            if ok { await resolveHeldRow(decision: "allow once: \(command)") }
            rig.scheduleRefresh()
        }
    }

    private func remember() {
        Task {
            guard await stillThePrompt(), let option = screen?.rememberOption else { return }
            let command = screen?.command ?? prompt.command
            let ok = await actions.perform(
                .answerPrompt(
                    session: prompt.session, keys: String(option.number),
                    reason: "OpenRig.app: \(option.text) for \(command)"),
                key: key, success: "Allowed and remembered")
            if ok { await resolveHeldRow(decision: "\(option.text): \(command)") }
            rig.scheduleRefresh()
        }
    }

    private func redirect() {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            guard await stillThePrompt(), let no = screen?.declineKey else { return }
            let command = screen?.command ?? prompt.command
            // The menu's own "No", found by its label: numbers shift between prompts, and on some
            // menus 3 switches the seat to auto mode.
            guard
                await actions.perform(
                    .answerPrompt(session: prompt.session, keys: no, reason: "OpenRig.app: decline \(command)"),
                    key: key, success: "Declined")
            else { return }
            if !text.isEmpty {
                // The decline sends no hook, so the daemon keeps the prompt and rig send refuses.
                // Wait until the pane shows no prompt, record that, then send the redirect.
                var gone = false
                for _ in 0..<10 {
                    if await rig.promptScreen(for: prompt.seatID) == nil {
                        gone = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard gone else {
                    changed = true
                    return
                }
                if prompt.check(against: await rig.currentStop(session: prompt.session)) != .gone {
                    await actions.perform(
                        .clearAttention(
                            session: prompt.session,
                            reason: "OpenRig.app: prompt declined; the pane shows no prompt"),
                        key: key, success: "Declined")
                }
                await actions.perform(
                    .send(session: prompt.session, text: text), key: key, success: "Declined and redirected")
            }
            redirecting = false
            reason = ""
            await resolveHeldRow(
                decision: text.isEmpty ? "declined: \(command)" : "declined: \(command); redirect: \(text)")
            rig.scheduleRefresh()
        }
    }

    /// When the prompt's work is parked on a person, unpark it with the decision.
    private func resolveHeldRow(decision: String) async {
        guard let linked, case .blocked(on: .outside) = workStatus(linked) else { return }
        await actions.perform(.resolve(id: linked.id, decision: decision), key: key, success: "Answered and resolved")
    }

    private func viewTerminal() {
        app.viewMode = .terminals
        if let seat = rig.seat(prompt.seatID) { rig.terminals.focus(seat) }
    }
}

/// One Needs-you entry: a prompt with its control, or a held row that opens in the inspector.
struct NeedsYouRow: View {
    let entry: NeedsYouEntry
    @Environment(RigStore.self) private var rig
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entry {
            case .prompt(let prompt, let linked):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.attention)
                    Text(rig.seat(prompt.seatID)?.displayName ?? prompt.session).font(.callout.weight(.semibold))
                    Text("asks to run").foregroundStyle(.secondary)
                    Spacer()
                    if let linked {
                        Button(shortQItemID(linked.id)) { selection.select(qitem: linked.id) }
                            .buttonStyle(.link)
                            .font(.caption.monospaced())
                            .help(linked.summary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let age = compactAge(since: prompt.observedAt, now: context.date) {
                            Text(age).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                PermissionControl(prompt: prompt, linked: linked, compact: true)
            case .seat(let seat, let presence):
                Button {
                    selection.select(seat: seat, in: rig)
                } label: {
                    HStack(spacing: 6) {
                        StatusDot(phase: .down(presence))
                        Text(seat.displayName).font(.callout.weight(.semibold))
                        Text(SeatPhase.down(presence).label).foregroundStyle(.orange)
                        Spacer()
                        if let item = seat.currentQItems.first {
                            Text("\(shortQItemID(item.id)) stalled").font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .qitem(let item):
                Button {
                    selection.select(qitem: item.id)
                } label: {
                    HStack(spacing: 6) {
                        let kind = forYou(item, me: rig.me)
                        Image(systemName: kind == .update ? "envelope" : "person.fill.questionmark")
                            .foregroundStyle(kind == .update ? Color.secondary : Color.attention)
                        Text(shortQItemID(item.id)).font(.caption.monospaced())
                        if kind != nil {
                            Text(rig.displayName(session: item.source)).fontWeight(.semibold)
                        }
                        Text(item.summary).lineLimit(2)
                        Spacer()
                        switch kind {
                        case .decision?: Text("Asks you").foregroundStyle(Color.attention)
                        case .update?: Text("FYI").foregroundStyle(.secondary)
                        case nil: Text(rig.displayName(session: item.destination)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(tint.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private var tint: Color {
        switch entry {
        case .seat: .orange
        case .qitem(let item) where forYou(item, me: rig.me) == .update: .secondary
        default: .attention
        }
    }

    private var isSelected: Bool {
        switch entry {
        case .qitem(let item): selection.qitemID == item.id
        case .seat(let seat, _): selection.seatID == seat.id
        case .prompt: false
        }
    }
}

/// Toolbar button with a count; opens the Needs-you list anchored to it.
struct NeedsYouButton: View {
    #if DEBUG
        /// The toolbar rebuilds this button (e.g. on a rig switch); the debug hook runs once per launch.
        @MainActor private static var debugOpened = false
    #endif
    var compact = false
    /// Rig › Needs You… bumps this to open the list.
    var requests = 0
    @Environment(AppStore.self) private var app
    @State private var open = false

    var body: some View {
        let entries = app.rig?.needsYou ?? []
        let elsewhere = app.elsewhere
        // FYIs are listed but don't make the button urgent: the red count is what waits on an answer. The same sum as
        // the sidebar's rig badges, other rigs' prompts included.
        let total = app.waitingEverywhere
        let urgent = total.urgent
        let fyi = total.fyis
        let any = urgent + fyi > 0
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                bell(urgent: urgent, any: any)
                if !compact { Text("Needs you") }
                if urgent > 0 {
                    CountBadge(count: urgent)
                } else if fyi > 0 {
                    CountBadge(count: fyi, quiet: true)
                }
            }
        }
        .accessibilityLabel(any ? "Needs you, \(urgent) waiting, \(fyi) FYI" : "Needs you")
        .help(any ? "\(urgent) waiting on you · \(fyi) FYI (⌘J)" : "Nothing needs you (⌘J)")
        .onChange(of: requests) { open = true }
        #if DEBUG
            // OPENRIG_DEBUG_NEEDS_YOU=1 opens the list once launch has settled, for screenshots without a click;
            // =open then opens the first row from another rig, as clicking it would.
            .task {
                let mode = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_NEEDS_YOU"]
                guard mode == "1" || mode == "open", !Self.debugOpened else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                Self.debugOpened = true
                open = true
                guard mode == "open", let first = app.elsewhere.first else { return }
                try? await Task.sleep(for: .seconds(2))
                app.open(first)
                open = false
            }
        #endif
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Group {
                if let rig = app.rig {
                    NeedsYouList(entries: entries, elsewhere: elsewhere, attention: app.attentionElsewhere) {
                        open = false
                    }
                    .environment(rig)
                } else {
                    NeedsYouList(entries: [], elsewhere: elsewhere, attention: app.attentionElsewhere) {
                        open = false
                    }
                }
            }
            .environment(app.selection)
            .environment(app.actions)
            .environment(app)
        }
    }
}

/// A count in a coral capsule, as on the design's Needs you button.
struct CountBadge: View {
    let count: Int
    /// Grey: only FYIs are waiting.
    var quiet = false
    /// On a selected (accent) row: a white ring keeps the capsule apart from the blue.
    var onSelection = false

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(quiet ? Color.quietFill : Color.attentionFill, in: .capsule)
            .overlay { if onSelection { Capsule().strokeBorder(.white, lineWidth: 1.5) } }
    }
}

extension NeedsYouButton {
    fileprivate func bell(urgent: Int, any: Bool) -> some View {
        Image(systemName: urgent > 0 ? "bell.badge.fill" : "bell")
            .foregroundStyle(urgent > 0 ? Color.attention : any ? .primary : .secondary)
    }
}

struct NeedsYouList: View {
    let entries: [NeedsYouEntry]
    /// Rows for the person from rigs other than the selected one.
    var elsewhere: [QItem] = []
    /// Other rigs' seats needing the person (prompts the app doesn't poll there), by rig.
    var attention: [(rig: String, count: Int)] = []
    /// Called after a row from another rig opens, which changes the selected rig.
    var opened: () -> Void = {}

    var body: some View {
        Group {
            if entries.isEmpty && elsewhere.isEmpty && attention.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
                    .frame(width: 360, height: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { NeedsYouRow(entry: $0) }
                        // One group per rig, under its name, in the order their first row needs you.
                        let rigs = (elsewhere.compactMap { rigName(ofSession: $0.source) } + attention.map(\.rig))
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        ForEach(Array(rigs.enumerated()), id: \.element) { index, rig in
                            Label(rig, systemImage: "circle.hexagongrid")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, entries.isEmpty && index == 0 ? 0 : 6)
                            if let seats = attention.first(where: { $0.rig == rig })?.count {
                                AttentionElsewhereRow(rig: rig, seats: seats, opened: opened)
                            }
                            ForEach(elsewhere.filter { rigName(ofSession: $0.source) == rig }) {
                                ElsewhereRow(item: $0, opened: opened)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 440)
                .frame(maxHeight: 520)
            }
        }
    }
}

/// Another rig's seats needing the person, such as a permission prompt. Opening it shows that rig's canvas.
struct AttentionElsewhereRow: View {
    let rig: String
    let seats: Int
    let opened: () -> Void
    @Environment(AppStore.self) private var app

    var body: some View {
        Button {
            app.open(rigNamed: rig)
            opened()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.attention)
                Text(seats == 1 ? "1 seat needs you" : "\(seats) seats need you").fontWeight(.semibold)
                Text("permission prompt or stopped").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(10)
            .background(Color.attention.opacity(0.06), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Opens \(rig)'s canvas")
    }
}

/// A row for the person from another rig. Opening it switches to that rig's queue board, where it can be answered.
struct ElsewhereRow: View {
    let item: QItem
    let opened: () -> Void
    @Environment(AppStore.self) private var app

    var body: some View {
        let fyi = forYou(item, me: app.me) == .update
        Button {
            app.open(item)
            opened()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: fyi ? "envelope" : "person.fill.questionmark")
                    .foregroundStyle(fyi ? Color.secondary : Color.attention)
                Text(shortQItemID(item.id)).font(.caption.monospaced())
                Text(item.source.split(separator: "@").first.map(String.init) ?? item.source).fontWeight(.semibold)
                Text(item.summary).lineLimit(2)
                Spacer()
                Text(fyi ? "FYI" : "Asks you").foregroundStyle(fyi ? Color.secondary : Color.attention)
                // Opens elsewhere, unlike this rig's rows, which answer in place.
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(10)
            .background((fyi ? Color.secondary : Color.attention).opacity(0.06), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Opens \(shortQItemID(item.id)) on \(rigName(ofSession: item.source) ?? "its rig")")
    }
}

/// The answer buttons' capsule, as in the design: a solid neutral pill for the main answer, tinted ones
/// for the rest. Neutral, not accent blue, so Allow once doesn't read as the default action.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, attention, danger, plain }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(.capsule)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(nsColor: .windowBackgroundColor)
        case .attention: .attention
        case .danger: .white
        case .plain: .primary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .primary
        case .attention: Color.attention.opacity(0.14)
        case .danger: .attention
        case .plain: Color.primary.opacity(0.08)
        }
    }
}

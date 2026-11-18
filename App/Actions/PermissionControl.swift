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
            if let screen {
                Text(screen.description.map { "\(screen.title): \($0)" } ?? screen.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !compact {
                Text("wants to run").font(.caption).foregroundStyle(.secondary)
            }
            // Never truncated: the risky part of a command is often at the end.
            Text(screen?.command ?? prompt.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            if changed {
                HStack {
                    Label("Prompt changed", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Button("View terminal") { viewTerminal() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            } else if redirecting {
                TextField("What to do instead (optional)", text: $reason, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(redirect)
                HStack(spacing: 6) {
                    Button(
                        reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Decline" : "Decline and send",
                        action: redirect
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(actions.isRunning(key) || screen?.declineKey == nil)
                    Button("Cancel") { redirecting = false }
                }
                .controlSize(compact ? .small : .regular)
            } else {
                HStack(spacing: 6) {
                    Button("Allow once", action: allowOnce)
                        .buttonStyle(.borderedProminent)
                        .disabled(actions.isRunning(key) || actions.offline || screen?.allowOnceKey == nil)
                        .help(
                            screen?.allowOnceKey == nil
                                ? "Can't read a plain Yes on screen; answer in the terminal" : "")
                    Button("No, redirect…") { redirecting = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(actions.isRunning(key))
                    Menu {
                        Button("View terminal") { viewTerminal() }
                        // The prompt's own "don't ask again" option; Claude Code saves the rule. Its exact wording
                        // is the label, so the user sees what scope they're granting.
                        Button(screen?.rememberLabel ?? "Always allow…", action: remember)
                            .disabled(screen?.rememberOption == nil || actions.offline || actions.isRunning(key))
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More answers")
                }
                .controlSize(compact ? .small : .regular)
            }
            ActionStatusLine(key: key)
        }
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
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
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
                        Image(systemName: "person.fill.questionmark").foregroundStyle(.red)
                        Text(shortQItemID(item.id)).font(.caption.monospaced())
                        Text(item.summary).lineLimit(2)
                        Spacer()
                        Text(rig.displayName(session: item.destination)).foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary, lineWidth: 1.5)
            }
        }
    }

    private var tint: Color {
        if case .seat = entry { .orange } else { .red }
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
    var compact = false
    @Environment(AppStore.self) private var app
    @State private var open = false

    var body: some View {
        let entries = app.rig?.needsYou ?? []
        Button {
            open.toggle()
        } label: {
            if compact {
                HStack(spacing: 4) {
                    bell(entries)
                    if !entries.isEmpty { Text("\(entries.count)").monospacedDigit() }
                }
            } else {
                Label {
                    Text(entries.isEmpty ? "Needs you" : "Needs you \(entries.count)")
                } icon: {
                    bell(entries)
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityLabel(entries.isEmpty ? "Needs you" : "Needs you, \(entries.count)")
        .help(entries.isEmpty ? "Nothing needs you" : "\(entries.count) waiting on you")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let rig = app.rig {
                NeedsYouList(entries: entries)
                    .environment(rig)
                    .environment(app.selection)
                    .environment(app.actions)
                    .environment(app)
            }
        }
    }
}

extension NeedsYouButton {
    fileprivate func bell(_ entries: [NeedsYouEntry]) -> some View {
        Image(systemName: entries.isEmpty ? "bell" : "bell.badge.fill")
            .foregroundStyle(entries.isEmpty ? Color.secondary : .red)
    }
}

struct NeedsYouList: View {
    let entries: [NeedsYouEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
                    .frame(width: 360, height: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { NeedsYouRow(entry: $0) }
                    }
                    .padding(12)
                }
                .frame(width: 440)
                .frame(maxHeight: 520)
            }
        }
    }
}

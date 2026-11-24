import RigClient
import SwiftUI

/// A seat stopped at a permission prompt (board 5A): the command in full, then Decline… and Allow once. Allow once
/// stays off until the end of the command has been on screen. An outcome replaces the buttons; the command above
/// never changes while it's shown.
struct PromptView: View {
    @Environment(RemoteSession.self) private var model
    var session: String

    @State private var shown: RelayPrompt?
    @State private var loadFailure: RelayDeskError?
    @State private var outcome: PromptOutcome?
    @State private var answeredAt: Date?
    /// A newer prompt found by a re-read, kept until the person asks to see it.
    @State private var newer: RelayPrompt?
    @State private var endSeen = false
    /// Bumped by `showNewPrompt`, so the command is a new view even when the new prompt reads the same.
    @State private var promptsShown = 0
    /// The command's bottom edge in the scroll content's coordinates, and where the scroll view stands.
    @State private var commandEnd: Double?
    @State private var viewport: Viewport?
    @State private var declining = Self.launchDeclining
    @State private var sending = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The rig, from the seat or the list row; kept once the prompt leaves the list.
    @State private var rig: String?

    init(session: String, rig: String? = nil) {
        self.session = session
        _rig = State(initialValue: rig)
    }

    var seat: String { shown?.seat ?? session.prefix { $0 != "@" }.description }

    var body: some View {
        Group {
            if let shown {
                content(shown)
            } else if let loadFailure {
                ContentUnavailableView {
                    Label(
                        loadFailure == .promptGone ? "This prompt is gone" : "Can't read this prompt",
                        systemImage: "exclamationmark.bubble")
                } description: {
                    Text(
                        loadFailure == .promptGone
                            ? "It was answered somewhere else, or \(seat) moved on."
                            : PromptWords.reason(loadFailure, mac: model.macName))
                }
            } else {
                ProgressView("Reading the prompt…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // As board 5A: nothing else near the two answers.
        .toolbarVisibility(.hidden, for: .tabBar)
        // Read once the desk exists. Then each check of the session re-reads the prompt, so a change shows before a tap,
        // never under it.
        .task(id: Reading(desk: model.desk != nil, status: model.status, checked: model.lastReached)) {
            if shown == nil { await load() } else { await recheck() }
        }
        .onChange(of: model.relayNeeds, initial: true) {
            if let item = model.needsYouList?.prompts.first(where: { $0.session == session }) { rig = item.rig }
        }
        .sheet(isPresented: $declining) {
            DeclineSheet(seat: seat) { reason in
                declining = false
                Task { await answer(.decline(reason: reason)) }
            }
        }
    }

    func content(_ prompt: RelayPrompt) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(prompt)
                // At accessibility sizes it sits above the command, where it's read before the end is reached.
                if typeSize.isAccessibilitySize, showsButtons, prompt.canAllowOnce, !endSeen {
                    Text("Scroll to the end of the command to allow it").font(.footnote).foregroundStyle(.secondary)
                }
                // Never shortened: the risky part of a command is often at its end.
                Text(prompt.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.attention.opacity(0.08), in: .rect(cornerRadius: 10))
                    .onGeometryChange(for: Double.self) {
                        Double($0.frame(in: .named(Self.content)).maxY)
                    } action: {
                        commandEnd = $0
                        checkEnd()
                    }
                    .accessibilityLabel("Command: \(prompt.command)")
                    .id("\(promptsShown) \(prompt.observedAt) \(prompt.command)")
                Text("Allow once lets this one command run. “Always allow” is on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // At accessibility sizes notes scroll with the command, so the pinned bar holds only the buttons.
                if typeSize.isAccessibilitySize { notes(prompt) }
            }
            .padding(20)
            .coordinateSpace(.named(Self.content))
        }
        // Content scrolled under the pinned buttons doesn't count as seen (`CommandEnd`).
        .onScrollGeometryChange(for: Viewport.self) {
            Viewport(
                offset: $0.contentOffset.y, topInset: $0.contentInsets.top, height: $0.containerSize.height,
                bottomInset: $0.contentInsets.bottom)
        } action: { _, new in
            viewport = new
            checkEnd()
        }
        #if DEBUG
            .defaultScrollAnchor(DebugHooks.promptScroll == "end" ? .bottom : nil)
        #endif
        .safeAreaInset(edge: .bottom) { bottom(prompt) }
    }

    /// The buttons stay until an answer may have gone out.
    var showsButtons: Bool { outcome?.keepsButtons ?? true }

    // MARK: Has the command's end been seen

    nonisolated static let content = "prompt content"

    struct Viewport: Equatable {
        var offset: Double
        var topInset: Double
        /// Between the insets: leaves out the navigation bar and the pinned buttons.
        var height: Double
        /// Logged only: `height` already leaves it out.
        var bottomInset: Double
    }

    /// Once seen, it stays seen, so scrolling back up doesn't turn Allow once off.
    func checkEnd() {
        guard !endSeen, let commandEnd, let viewport else { return }
        endSeen = CommandEnd.isSeen(
            endY: commandEnd, offsetY: viewport.offset, topInset: viewport.topInset, visibleHeight: viewport.height)
        #if DEBUG
            DebugHooks.log.notice(
                "command end \(commandEnd) offset \(viewport.offset) top inset \(viewport.topInset) height \(viewport.height) bottom inset \(viewport.bottomInset) seen \(endSeen)"
            )
        #endif
    }

    func header(_ prompt: RelayPrompt) -> some View {
        let state = PromptWords.state(outcome)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(state.colour)
                Text([state.words, rig, age(prompt)].compactMap { $0 }.joined(separator: " · "))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Text(outcome == nil ? "\(prompt.seat) asks to run" : "\(prompt.seat) asked to run")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }

    func age(_ prompt: RelayPrompt) -> String? {
        if outcome == .allowed { return "now" }
        guard outcome == nil, let at = try? Date(prompt.observedAt, strategy: .iso8601) else { return nil }
        let minutes = Int(Date.now.timeIntervalSince(at) / 60)
        return minutes < 1 ? "now" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    @ViewBuilder func bottom(_ prompt: RelayPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize { pinnedTitle(prompt) } else { notes(prompt) }
            if showsButtons { buttons(prompt) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    var showNew: (() -> Void)? {
        outcome?.offersNewPrompt == true ? { Task { await showNewPrompt() } } : nil
    }

    /// At accessibility sizes the outcome's title stays where the buttons were, and its detail scrolls.
    @ViewBuilder func pinnedTitle(_ prompt: RelayPrompt) -> some View {
        Group {
            if let outcome, !outcome.keepsButtons {
                OutcomeView(
                    outcome: outcome, seat: prompt.seat, mac: model.macName, at: answeredAt, part: .title,
                    showNew: showNew)
            } else if outcome == .unreachable {
                Label("Couldn't reach \(model.macName)", systemImage: "wifi.exclamationmark").font(.headline)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// The outcome in place of the buttons, or what holds the buttons back.
    @ViewBuilder func notes(_ prompt: RelayPrompt) -> some View {
        let large = typeSize.isAccessibilitySize
        if let outcome, !outcome.keepsButtons {
            OutcomeView(
                outcome: outcome, seat: prompt.seat, mac: model.macName, at: answeredAt, part: large ? .detail : .all,
                showNew: large ? nil : showNew)
        } else {
            if outcome == .unreachable {
                if large {
                    Text("Nothing was sent.").font(.footnote)
                } else {
                    Label("Couldn't reach \(model.macName). Nothing was sent.", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                }
            }
            if !prompt.canAllowOnce {
                Text("\(model.macName) can't find this prompt's plain Yes. Allow it in the terminal on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !endSeen, !typeSize.isAccessibilitySize {
                Text("Scroll to the end of the command to allow it")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    func buttons(_ prompt: RelayPrompt) -> some View {
        // Side by side; stacked when large text makes them too wide, so neither label is cut.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                declineButton(prompt); allowButton(prompt)
            }
            VStack(spacing: 12) {
                allowButton(prompt); declineButton(prompt)
            }
        }
        .controlSize(.large)
        .disabled(sending || model.desk == nil)
        // Pinned, so they can't grow to cover the command.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    func declineButton(_ prompt: RelayPrompt) -> some View {
        Button {
            declining = true
        } label: {
            Text("Decline…").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Color.attention)
        .disabled(!prompt.canDecline)
    }

    func allowButton(_ prompt: RelayPrompt) -> some View {
        Button {
            Task { await answer(.allowOnce) }
        } label: {
            Text("Allow once").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!prompt.canAllowOnce || !endSeen)
    }

    // MARK: Reading and answering

    /// Changes on every check of the session, not only when the list changes: the same command asked again is a new
    /// prompt with the same list row.
    struct Reading: Equatable {
        var desk: Bool
        var status: RemoteStatus?
        var checked: Date?
    }

    /// Until the session has read the Mac once there's no desk yet: wait while it connects, rather than fail.
    func load() async {
        guard let desk = model.desk else {
            loadFailure = model.status == nil ? nil : .unreachable("")
            return
        }
        do throws(RelayDeskError) {
            shown = try await desk.prompt(session: session)
            loadFailure = nil
        } catch {
            loadFailure = error
        }
        #if DEBUG
            await runLaunchHooks()
        #endif
    }

    func recheck() async {
        guard let prompt = shown, outcome == nil || outcome == .unreachable, !sending, let desk = model.desk else {
            return
        }
        let now: Result<RelayPrompt, RelayDeskError>
        do throws(RelayDeskError) { now = .success(try await desk.prompt(session: session)) } catch {
            now = .failure(error)
        }
        guard outcome == nil || outcome == .unreachable, !sending, shown == prompt else { return }
        switch PromptCheck(shown: prompt, now: now) {
        case .same, .unknown: break
        case .changed(let new):
            newer = new
            outcome = .changed
        case .gone: outcome = .gone
        }
    }

    func answer(_ action: PromptOutcome.Action) async {
        guard let prompt = shown, let desk = model.desk, !sending else { return }
        sending = true
        let result: Result<Void, RelayDeskError>
        do throws(RelayDeskError) {
            switch action {
            case .allowOnce: try await desk.allowOnce(prompt)
            case .decline(let reason): try await desk.decline(prompt, reason: reason)
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        sending = false
        answeredAt = .now
        let next = PromptOutcome(action, result)
        outcome = next
        if !next.keepsButtons { await model.refresh() }
    }

    func showNewPrompt() async {
        var next = newer
        if next == nil, let desk = model.desk { next = try? await desk.prompt(session: session) }
        guard let next else {
            outcome = .gone
            return
        }
        shown = next
        promptsShown += 1
        newer = nil
        outcome = nil
        answeredAt = nil
        endSeen = false
        // The old command's end no longer counts. The new command's text is a new view (`.id`), so it reports its own.
        commandEnd = nil
    }

    static var launchDeclining: Bool {
        #if DEBUG
            DebugHooks.promptAction == "decline"
        #else
            false
        #endif
    }

    #if DEBUG
        func runLaunchHooks() async {
            guard DebugHooks.openPrompt == session, shown != nil else { return }
            if let forced = DebugHooks.promptOutcome {
                answeredAt = .now
                outcome = forced
                return
            }
            switch DebugHooks.promptAction {
            case "allow":
                endSeen = true
                await answer(.allowOnce)
            case let action? where action.hasPrefix("decline:"):
                await answer(.decline(reason: String(action.dropFirst("decline:".count))))
            default: break
            }
        }
    #endif
}

/// What happened, in place of the buttons (board 5A, "After").
struct OutcomeView: View {
    var outcome: PromptOutcome
    var seat: String
    var mac: String
    var at: Date?
    /// At accessibility sizes the title is pinned and the detail scrolls, so each shows alone.
    var part: Part = .all
    var showNew: (() -> Void)?

    enum Part { case all, title, detail }

    var body: some View {
        let words = PromptWords.outcome(outcome, seat: seat, mac: mac, at: at)
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if part != .detail { Text(words.title).font(.headline) }
                    if part != .title { Text(words.detail).font(.subheadline).foregroundStyle(.secondary) }
                }
            } icon: {
                if outcome == .allowed, part != .detail {
                    Image(systemName: "checkmark").foregroundStyle(Color.statusGood)
                }
            }
            .accessibilityElement(children: .combine)
            if let showNew {
                Button(action: showNew) {
                    Text("Show the new prompt").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
    }
}

/// Decline… takes an optional reason first (board 5A, After 1).
struct DeclineSheet: View {
    var seat: String
    var decline: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = Self.launchReason
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Optional. Leave empty to just decline.", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } header: {
                    Text("Tell \(seat) what to do instead")
                } footer: {
                    Text("\(seat) stops and waits. If you write something, it gets your text right after the decline.")
                }
            }
            .navigationTitle("Decline \(seat)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    decline(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.attentionFill)
                .controlSize(.large)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .padding(20)
            }
        }
        // Full height at accessibility sizes, so the pinned button never covers the field.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    static var launchReason: String {
        #if DEBUG
            DebugHooks.environment["OPENRIG_DEBUG_DECLINE_TEXT"] ?? ""
        #else
            ""
        #endif
    }
}

/// The words for each outcome. Each says whether anything was sent, since that decides what the person does next.
enum PromptWords {
    static func state(_ outcome: PromptOutcome?) -> (words: String, colour: Color) {
        switch outcome {
        case .allowed?: ("Working", .statusGood)
        case .declined?: ("Declined", .secondary)
        case .gone?, .probablyAnswered?: ("No longer waiting", .secondary)
        case .changed?, .answeredThenNewPrompt?: ("Prompt changed", .attention)
        // The answer may have run: the seat's state isn't known.
        case .lostReply?: ("Not confirmed", .secondary)
        default: ("Stopped at a prompt", .attention)
        }
    }

    static func outcome(_ outcome: PromptOutcome, seat: String, mac: String, at: Date?) -> (
        title: String, detail: String
    ) {
        let time = at.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return switch outcome {
        case .allowed: ("You allowed this once\(time)", "\(seat) is working again. The prompt has left Needs you.")
        case .declined(let withNote):
            (
                "You declined\(time)",
                withNote ? "\(seat) stopped and got your text." : "\(seat) stopped and waits for you."
            )
        case .gone:
            (
                "This prompt is gone",
                "It was answered somewhere else, or \(seat) moved on. Nothing was sent from this phone."
            )
        case .changed: ("\(seat) now asks to run something else", "Nothing was sent. Above is the old command.")
        case .probablyAnswered:
            (
                "Your answer probably went through",
                "\(mac)'s reply was lost, and the prompt has left since. Check \(seat) on the Mac."
            )
        case .answeredThenNewPrompt:
            (
                "\(seat) asks to run something new",
                "Your answer probably went through: \(mac)'s reply was lost, and \(seat) has stopped at a new prompt."
            )
        case .cannotAllowOnce:
            ("Answer this one on the Mac", "\(mac) can't find this prompt's plain Yes on screen. Nothing was sent.")
        case .cannotDecline:
            ("Answer this one on the Mac", "\(mac) can't find this prompt's No on screen. Nothing was sent.")
        case .lostReply:
            (
                "No reply from \(mac)",
                "Your answer went out, but no reply came back, so it may have been done. Look at \(seat) on the Mac before you answer again."
            )
        case .unreachable: ("Couldn't reach \(mac)", "Nothing was sent.")
        case .failed(let message): ("That didn't go through", message)
        }
    }

    /// Why a read failed, for the screen that has no prompt to show.
    static func reason(_ error: RelayDeskError, mac: String) -> String {
        switch error {
        case .unreachable: "Couldn't reach \(mac). Prompts show only when this phone reaches the Mac through Wi-Fi."
        case .actorMismatch(let message), .notFound(let message), .failed(let message), .decoding(let message):
            message
        default: "\(mac) didn't give this prompt. Look at the seat on the Mac."
        }
    }
}

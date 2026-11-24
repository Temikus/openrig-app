import RigClient
import RigModel
import SwiftUI

/// One ask: every question on one page with one Send (board 2, A), or the record of what was sent.
/// The questions sit in `QuestionsForm`, so a step-by-step view can replace it later without touching the rest.
struct QuestionView: View {
    @Environment(RemoteSession.self) private var model
    var id: String
    /// The ask as last seen, so the screen stays when it leaves the list after Send.
    @State private var lastSeen: AppRequest?

    var request: AppRequest? { model.shownRequests?.first { $0.id == id } ?? lastSeen }

    var body: some View {
        Group {
            if let request {
                if let record = model.sent[id] {
                    SentRecordView(request: request, record: record)
                } else {
                    AskForm(request: request)
                }
            } else {
                ProgressView("Loading the ask…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // As board 2: the ask has the whole screen, and Send sits where the tab bar was.
        .toolbarVisibility(.hidden, for: .tabBar)
        .onChange(of: model.shownRequests?.first { $0.id == id }, initial: true) { _, live in
            if let live { lastSeen = live }
        }
        #if DEBUG
            .task(id: model.shownRequests?.contains { $0.id == id } == true) {
                guard DebugHooks.openAsk == id, model.sent[id] == nil,
                    let live = model.shownRequests?.first(where: { $0.id == id })
                else { return }
                if let draft = DebugHooks.draft, model.draft(for: live).isEmpty { model.setDraft(draft, for: live) }
                if DebugHooks.send { await model.send(live) }
            }
        #endif
    }
}

/// Who asked, and the ask's own words.
struct AskHeader: View {
    var request: AppRequest
    var asked = "asks you"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text([request.seat + " " + asked, request.rig].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(request.headline).font(.title2.bold())
            if let rest = request.bodyAfterHeadline {
                Text(rest).foregroundStyle(.secondary)
            }
            if let detail = request.humanDetail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AppRequest {
    var bodyAfterHeadline: String? {
        guard let body, let newline = body.firstIndex(where: \.isNewline) else { return nil }
        let rest = body[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}

/// The questions and Send.
struct AskForm: View {
    @Environment(RemoteSession.self) private var model
    var request: AppRequest

    var draft: AppAnswerDraft { model.draft(for: request) }
    var submissions: [AppAnswerDraft.Submission]? { draft.submissions(for: request) }
    var sending: Bool { model.sending.contains(request.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AskHeader(request: request)
                if request.occupantAuthorityUnknown {
                    Label(
                        "OpenRig can't confirm the seat that asked is still current. Your answer is saved on the ask either way.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if !request.isAnswerable {
                    CantAnswer(reason: request.unsupportedReason)
                } else if draft.reply != nil {
                    ReplyField(request: request)
                } else {
                    QuestionsForm(request: request)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if request.isAnswerable { sendBar }
        }
    }

    var sendBar: some View {
        VStack(spacing: 8) {
            Text(progress).font(.footnote).foregroundStyle(.secondary)
            Button {
                Task { await model.send(request) }
            } label: {
                Text(draft.reply != nil ? "Send reply" : "Send answers").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(submissions == nil || sending || model.shownRequests == nil)
        }
        .padding(20)
        .background(.bar)
    }

    var progress: String {
        if sending { return "Sending…" }
        if case .connected = model.status {} else { return "Not connected to \(model.macName)" }
        if draft.reply != nil { return "Your reply answers the whole ask." }
        let open = request.unansweredQuestions.count
        return "\(draft.pickedCount(in: request)) of \(open) answered"
    }
}

/// Each open question with its options. A question answered elsewhere shows what was recorded.
struct QuestionsForm: View {
    @Environment(RemoteSession.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var request: AppRequest

    var labelLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.headline)
                    if let recorded = request.humanAnswers[question.id] {
                        Text("Answered: \(recorded.text(in: question))")
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: .rect(cornerRadius: 16))
                    } else {
                        options(question)
                    }
                }
            }
            Button("Reply in your own words instead…") {
                var draft = model.draft(for: request)
                draft.reply = ""
                model.setDraft(draft, for: request)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }

    func options(_ question: HumanQuestion) -> some View {
        let picked = model.draft(for: request).picks[question.id]
        return VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().padding(.leading, 16) }
                Button {
                    var draft = model.draft(for: request)
                    draft.picks[question.id] = picked == option.id ? nil : option.id
                    model.setDraft(draft, for: request)
                } label: {
                    HStack {
                        // Side by side at normal sizes; stacked at accessibility sizes, where a line holds a word.
                        labelLayout {
                            Text(option.label).foregroundStyle(.primary)
                            if option.recommended == true { Text("suggested").foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        if picked == option.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .padding(16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked == option.id ? .isSelected : [])
                .accessibilityHint(option.recommended == true ? "Suggested" : "")
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// The person's own words, in place of the options.
struct ReplyField: View {
    @Environment(RemoteSession.self) private var model
    var request: AppRequest
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reply to \(request.seat)").font(.headline)
            TextField("Your reply", text: text, axis: .vertical)
                .lineLimit(4...)
                .focused($focused)
                .padding(16)
                .background(.background.secondary, in: .rect(cornerRadius: 16))
            Text("Your reply answers the whole ask, in place of the options.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Choose from the options instead") {
                var draft = model.draft(for: request)
                draft.reply = nil
                model.setDraft(draft, for: request)
            }
        }
        .onAppear { if model.draft(for: request).reply?.isEmpty == true { focused = true } }
    }

    var text: Binding<String> {
        Binding(
            get: { model.draft(for: request).reply ?? "" },
            set: {
                var draft = model.draft(for: request)
                draft.reply = $0
                model.setDraft(draft, for: request)
            })
    }
}

/// Why the phone can't answer this ask.
struct CantAnswer: View {
    var reason: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("This ask can't be answered here").font(.headline)
                Text(explanation).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "info.circle")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    var explanation: String {
        switch reason {
        case "unsupported_request_kind": "It isn't a question with options. Answer it in OpenRig on the Mac."
        case "request_not_pending": "It's already answered or closed."
        case "request_stale": "The seat that asked has been replaced, so an answer would reach no one."
        case "source_unavailable": "Its content is no longer on the Mac."
        case let other?: "The Mac says: \(other)."
        case nil: "The Mac didn't say why."
        }
    }
}

/// After Send: what went, and what the daemon said happened to it (board 2, after Send).
struct SentRecordView: View {
    @Environment(RemoteSession.self) private var model
    var request: AppRequest
    var record: SentAnswer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AskHeader(request: request, asked: "asked you")
                outcome
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your answers").font(.footnote).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(record.answers.enumerated()), id: \.offset) { index, line in
                            if index > 0 { Divider().padding(.leading, 16) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.question).font(.footnote).foregroundStyle(.secondary)
                                Text(line.answer)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                }
                if lookAgain {
                    Button("Look at the ask again") { model.forgetSent(request.id) }
                }
            }
            .padding(20)
        }
    }

    var lookAgain: Bool {
        switch record.outcome {
        case .changed, .failed, .stillOpen: true
        default: false
        }
    }

    var outcome: some View {
        let (title, detail, good) = words
        return VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: good ? "checkmark" : "exclamationmark.circle")
                .font(.headline)
                .foregroundStyle(good ? Color.primary : Color.statusBad)
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    var words: (String, String, Bool) {
        let seat = request.seat
        let time = record.at.formatted(date: .omitted, time: .shortened)
        return switch record.outcome {
        case .returned:
            ("Returned to \(seat)", "Sent at \(time). Your answers are in \(seat)'s queue.", true)
        case .kept(let message):
            (
                "Saved, not delivered yet",
                "No agent could read your answers, so this ask is still waiting. They stay on the ask. You don't need to send again."
                    + (message.map { "\n\n\($0)" } ?? ""), false
            )
        case .alreadyAnswered:
            ("Already answered", "Someone answered this ask first, so yours weren't sent.", false)
        case .stillOpen:
            ("Some answers went in", "The ask still has questions open. Look at it again to answer them.", false)
        case .changed:
            ("The ask changed", "It changed before your answers went in. Look at it again; your picks are kept.", false)
        case .erased:
            ("The ask was erased", "Its content is no longer on the Mac.", false)
        case .notFinished:
            (
                "Not confirmed yet",
                "The phone couldn't confirm your answers reached \(model.macName). It sends the same answers again each time it checks. You don't need to send again.",
                false
            )
        case .failed(let message):
            ("Not sent", message, false)
        }
    }
}

extension AppHumanAnswer {
    /// The option's label, or the reply's words.
    func text(in question: HumanQuestion) -> String {
        switch self {
        case .option(let id): question.options.first { $0.id == id }?.label ?? id
        case .typedReply(let text): text
        case .unrecognized: "an answer this app can't show"
        }
    }
}

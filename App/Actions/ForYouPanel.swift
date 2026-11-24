import AppKit
import RigClient
import RigDomain
import RigModel
import SwiftUI

/// The answer controls for a row an agent sent the person: approve or deny a decision, acknowledge an update.
/// Closing records the answer on the row; the asker learns of it only from a message, so one goes by default.
struct ForYouPanel: View {
    let item: QItem
    let kind: ForYou
    @Environment(RigStore.self) private var rig
    @Environment(ActionStore.self) private var actions
    @State private var note = ""
    @State private var replying = false

    /// Shared with QItemInspector, which shows the outcome once the closed row drops this panel.
    static func key(_ item: QItem) -> String { "answer:\(item.id)" }
    private var key: String { Self.key(item) }
    private var asker: String { rig.displayName(session: item.source) }
    /// Picks, Tell and what already went out, kept in ActionStore: the inspector rebuilds this panel for each row.
    private var draft: AnswerDraft { actions.answers.draft(key, on: item) }
    private func kept<Value>(_ field: WritableKeyPath<AnswerDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: field] }, set: { value in update { $0[keyPath: field] = value } })
    }
    private func update(_ change: (inout AnswerDraft) -> Void) {
        var next = draft
        change(&next)
        actions.answers.set(next, for: key)
    }
    /// None on a made-up row, so Tell and Reply… never offer to type into a real seat.
    private var askerSeat: Seat? { rig.isMadeUp(item.id) ? nil : rig.seat(session: item.source) }
    private var busy: Bool { actions.isRunning(key) || actions.offline }
    /// Tell only reaches a seat in this rig; anywhere else the answer is only recorded on the row.
    private var canTell: Bool { askerSeat != nil }

    private var title: String {
        if isSweepFinding(item) { return "A row has waited too long. Nothing to decide here" }
        return kind == .decision ? "\(asker) asks you to decide" : "\(asker) sent you an update"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: kind == .decision ? "person.fill.questionmark" : "envelope")
                    .foregroundStyle(kind == .decision ? Color.attention : .secondary)
            }
            .font(.callout.weight(.semibold))
            RowEvidence(item: item)
            switch kind {
            case .decision where item.asksHuman: questions
            case .decision: decision
            case .update: update
            }
            if replying, let askerSeat {
                // Under the row's key, so a made-up row's reply is refused even if the seat above lets it show.
                MessageComposer(seat: askerSeat, inline: true, autofocus: true, key: "\(key)|reply") {
                    replying = false
                    update { $0.replied = true }
                }
            }
        }
        .padding(12)
        .background((kind == .decision ? Color.attention : .secondary).opacity(0.06), in: .rect(cornerRadius: 10))
    }

    private var decision: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                canTell && draft.tell ? "Reason or next step (optional)" : "Note (recorded on the row)", text: $note,
                axis: .vertical
            )
            .lineLimit(1...4)
            .keepsDraft($note, key, "note")
            .help(
                canTell && draft.tell
                    ? "Goes to \(asker) with your answer, and onto the row." : "Recorded on the row only.")
            if canTell {
                Toggle("Tell \(asker)", isOn: kept(\.tell))
                    .toggleStyle(.checkbox)
                    .help("Also sends your answer to \(asker) with rig send. Closing alone only records it on the row.")
            } else {
                Text(
                    rig.isMadeUp(item.id)
                        ? ActionStore.madeUp : "\(asker) isn't in this rig, so your answer is only recorded on the row."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                Button("Deny") { Task { await answer(.deny) } }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                Button("Approve") { Task { await answer(.approve) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy)
                    .help("Approve (⌘↩)")
            }
        }
    }

    /// One radio list per question, then one send: the daemon returns the answers to the asker and closes the row.
    @ViewBuilder private var questions: some View {
        if item.humanQuestions.isEmpty {
            questionsWithoutShape
        } else {
            let missing = draft.answers.missing(in: item).count
            VStack(alignment: .leading, spacing: 12) {
                ForEach(item.humanQuestions) { question in
                    QuestionPicker(
                        question: question, recorded: item.humanAnswers[question.id], answers: kept(\.answers))
                }
                HStack {
                    ActionStatusLine(key: key)
                    Spacer()
                    let total = item.humanQuestions.count
                    Text("\(total - missing) of \(total) answered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    replyButton
                    Button("Send answers") { Task { await sendAnswers() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(busy || missing > 0)
                        .help(missing > 0 ? "Answer every question first." : "Send answers (⌘↩)")
                }
            }
        }
    }

    private func sendAnswers() async {
        let answers = draft.answers
        let calls = answers.calls(for: item)
        var sentCount = 0
        let done = await answers.run(on: item) { call in
            sentCount += 1
            // Only the last call finishes the ask; earlier ones only record a pick.
            let last = sentCount == calls.count
            return await actions.answer(
                call, on: item.id, key: key, success: last ? "Answers sent to \(asker)" : "Recorded")
        }
        if done { actions.clearDrafts(for: key) }
    }

    /// A row whose questions didn't decode: answer in your own words, then close.
    private var questionsWithoutShape: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "\(asker) asks questions with options. Answer them in the TUI's Feed, or reply here in your own words."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                ActionStatusLine(key: key)
                Spacer()
                replyButton
                // Once answered in their own words, the person clears the row; the agent isn't asked to.
                Button("Done") { Task { await answer(.answered) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help("Closes the row without telling \(asker). Reply first if you haven't answered.")
            }
        }
    }

    private var update: some View {
        HStack {
            ActionStatusLine(key: key)
            Spacer()
            replyButton
            Button("Got it") { Task { await answer(.acknowledge) } }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .help("Closes the row: you've read it and nothing follows.")
        }
    }

    @ViewBuilder private var replyButton: some View {
        if askerSeat != nil {
            Button(replying ? "Cancel reply" : "Reply…") { replying.toggle() }.buttonStyle(.bordered)
        }
    }

    /// A failed message or close shows its error beside the buttons and leaves the row open.
    private func answer(_ verdict: Answer.Verdict) async {
        let draft = draft
        let answer = Answer(verdict, note: note, tell: draft.tell && canTell, replied: draft.replied)
        let outcome = answer.outcome(asker: asker, told: answer.message(for: item) != nil || draft.sent != nil)
        let result = await answer.run(on: item, alreadySent: draft.sent) { action in
            // The outcome waits for the close, so a close that then fails never shows a success first.
            if case .send = action {
                return await actions.perform(action, key: key, success: "\(asker) told; closing…")
            }
            return await actions.perform(action, key: key, success: outcome)
        }
        if result.closed {
            actions.clearDrafts(for: key)
        } else {
            update { $0.sent = result.sent }
        }
    }
}

/// One question as a radio list, plus "Other…" for the person's own words.
private struct QuestionPicker: View {
    let question: HumanQuestion
    /// The answer already recorded on the row, from an earlier send: an option or typed words.
    let recorded: HumanAnswer?
    @Binding var answers: QuestionAnswers

    /// Can't clash with an option: the daemon allows only letters, digits, "-" and "_" in ids.
    private static let other = "(other)"

    private var selection: Binding<String?> {
        Binding {
            answers.other[question.id] != nil ? Self.other : answers.picks[question.id]
        } set: { value in
            if value == Self.other {
                answers.picks[question.id] = nil
                answers.other[question.id] = answers.other[question.id] ?? ""
            } else {
                answers.other[question.id] = nil
                answers.picks[question.id] = value
            }
        }
    }

    /// The asker's suggestion is marked in grey, so the mark doesn't read as part of the answer.
    private func label(_ option: HumanQuestion.Option) -> AttributedString {
        var text = AttributedString(option.label)
        if option.recommended == true {
            var mark = AttributedString("  suggested")
            mark.foregroundColor = .secondary
            text += mark
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let recorded {
                Label(recorded.text(in: question), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(question.question, selection: selection) {
                    ForEach(question.options) { option in
                        Text(label(option)).tag(String?.some(option.id))
                    }
                    Text("Other…").tag(String?.some(Self.other))
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if answers.other[question.id] != nil {
                    TextField(
                        "Your answer",
                        text: Binding {
                            answers.other[question.id] ?? ""
                        } set: {
                            answers.other[question.id] = $0
                        },
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                }
            }
        }
    }
}

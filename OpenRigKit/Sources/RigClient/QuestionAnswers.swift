import RigModel

/// The person's answers to an ask's questions, sent with the daemon's `answer` verb.
public struct QuestionAnswers: Sendable, Equatable {
    /// Question id → the option picked.
    public var picks: [String: String] = [:]
    /// Question id → the person's own words, where they chose "Other…" instead of an option.
    public var other: [String: String] = [:]

    public init(picks: [String: String] = [:], other: [String: String] = [:]) {
        self.picks = picks
        self.other = other
    }

    /// Questions still open on the row that have neither a pick nor words.
    public func missing(in item: QItem) -> [HumanQuestion] {
        open(in: item).filter { q in
            if let words = other[q.id] { return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return picks[q.id] == nil
        }
    }

    /// Choices first: each is recorded on the row, and the one that completes the set returns them to the asker and
    /// closes the ask. Any "Other…" words go last in one call; the daemon files them under the first question still
    /// unanswered, returns everything and closes. Questions the row already records (an earlier, interrupted send)
    /// aren't sent again.
    public func calls(for item: QItem) -> [AskAnswer] {
        let open = open(in: item)
        let choices = open.compactMap { q -> AskAnswer? in
            guard other[q.id] == nil, let option = picks[q.id] else { return nil }
            return .choice(question: q.id, option: option)
        }
        let words = open.compactMap { q -> String? in
            guard let text = other[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            // Several answers in one message: name each question so the asker can tell them apart.
            return open.filter { other[$0.id] != nil }.count == 1 ? text : "\(q.question) \(text)"
        }
        return choices + (words.isEmpty ? [] : [.words(words.joined(separator: "\n"))])
    }

    /// Sends the calls in order and stops at the first failure; what was recorded stays on the row for a retry.
    public func run(
        on item: QItem, isolation: isolated (any Actor)? = #isolation, perform: (AskAnswer) async -> Bool
    ) async -> Bool {
        for call in calls(for: item) {
            guard await perform(call) else { return false }
        }
        return true
    }

    /// Only answers to questions still open on the row, and picks of options it still offers.
    func kept(for item: QItem) -> QuestionAnswers {
        let open = Dictionary(open(in: item).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return QuestionAnswers(
            picks: picks.filter { id, option in open[id]?.options.contains { $0.id == option } == true },
            other: other.filter { open[$0.key] != nil })
    }

    private func open(in item: QItem) -> [HumanQuestion] {
        item.humanQuestions.filter { item.humanAnswers[$0.id] == nil }
    }
}

/// What the person set on a row's For You panel and hasn't sent yet. The typed note is in `ActionStore.drafts`.
public struct AnswerDraft: Sendable, Equatable {
    public var answers = QuestionAnswers()
    /// Also send the answer to the asker. Kept with the note: off, the note is for the row only.
    public var tell = true
    /// The message that already reached the asker, so a retry after a failed close doesn't send it twice.
    public var sent: RigAction?
    /// A reply went out from the panel, so Done can record the question as answered.
    public var replied = false

    public init(
        answers: QuestionAnswers = QuestionAnswers(), tell: Bool = true, sent: RigAction? = nil, replied: Bool = false
    ) {
        self.answers = answers
        self.tell = tell
        self.sent = sent
        self.replied = replied
    }
}

/// Half-answered rows, by the panel's action key, so they outlive the panel that showed them. Memory only.
public struct AnswerDrafts: Sendable, Equatable {
    private var byKey: [String: AnswerDraft] = [:]

    public init() {}

    /// The draft as the row stands now: a question it no longer asks, or already records, shows no pick.
    public func draft(_ key: String, on item: QItem) -> AnswerDraft {
        guard var draft = byKey[key] else { return AnswerDraft() }
        draft.answers = draft.answers.kept(for: item)
        return draft
    }

    public mutating func set(_ draft: AnswerDraft, for key: String) {
        byKey[key] = draft == AnswerDraft() ? nil : draft
    }

    public mutating func clear(_ key: String) { byKey[key] = nil }
}

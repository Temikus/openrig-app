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

    private func open(in item: QItem) -> [HumanQuestion] {
        item.humanQuestions.filter { item.humanAnswers[$0.id] == nil }
    }
}

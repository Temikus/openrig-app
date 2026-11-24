import Foundation

/// What the person has picked on one ask but not sent: an option per open question, or their own words.
public struct AppAnswerDraft: Sendable, Equatable {
    /// Question id → option id.
    public var picks: [String: String]
    /// Set when the person replies in their own words. It answers the whole ask, so the picks wait.
    public var reply: String?

    public init(picks: [String: String] = [:], reply: String? = nil) {
        self.picks = picks
        self.reply = reply
    }

    public var isEmpty: Bool { picks.isEmpty && reply == nil }

    /// One `POST /answers/:id`: the contract takes one question per submission.
    public struct Submission: Sendable, Equatable {
        public var questionID: String
        public var form: AppAnswerForm

        public init(questionID: String, form: AppAnswerForm) {
            self.questionID = questionID
            self.form = form
        }

        /// The exact body, at `revision`: the read's for the first submission, the last receipt's after that.
        public func binding(on request: AppRequest, at revision: String, as actor: String) -> AppAnswerBinding {
            AppAnswerBinding(
                actor: actor, requestId: request.id, questionId: questionID, episodeKey: request.episodeKey,
                expectedRevision: revision, answer: form)
        }
    }

    /// Picks only for questions still open, of options still offered. The reply stays.
    public func kept(for request: AppRequest) -> AppAnswerDraft {
        let open = Dictionary(request.unansweredQuestions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return AppAnswerDraft(
            picks: picks.filter { id, option in open[id]?.options.contains { $0.id == option } == true },
            reply: reply)
    }

    public func pickedCount(in request: AppRequest) -> Int { kept(for: request).picks.count }

    /// What Send submits, in the ask's order. Nil until it can send: every open question picked, or a reply the
    /// daemon would take. A reply goes under the first open question, as the contract requires.
    public func submissions(for request: AppRequest) -> [Submission]? {
        let open = request.unansweredQuestions
        guard request.isAnswerable, request.decisionRevision != nil, let first = open.first else { return nil }
        if let reply {
            guard let text = AppAnswerBinding.sendableReply(reply) else { return nil }
            return [Submission(questionID: first.id, form: .typedReply(text))]
        }
        let kept = kept(for: request).picks
        guard open.allSatisfy({ kept[$0.id] != nil }) else { return nil }
        return open.map { Submission(questionID: $0.id, form: .option(kept[$0.id]!)) }
    }
}

/// Half-made answers by ask id, so they outlive the screen that showed them. Memory only.
public struct AppAnswerDrafts: Sendable, Equatable {
    private var byID: [String: AppAnswerDraft] = [:]

    public init() {}

    /// The draft as the ask stands now: a question it no longer asks, or already records, shows no pick.
    public func draft(for request: AppRequest) -> AppAnswerDraft {
        byID[request.id]?.kept(for: request) ?? AppAnswerDraft()
    }

    public mutating func set(_ draft: AppAnswerDraft, for id: String) {
        byID[id] = draft.isEmpty ? nil : draft
    }

    public mutating func clear(_ id: String) { byID[id] = nil }
}

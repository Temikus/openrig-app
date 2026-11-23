import Foundation

// The daemon's phone-app contract, `/api/apps/v1` (rig 0.7.21 core-app.md): see a person's structured asks and answer
// them as that person, with a credential the owner issues to the app.

/// `GET /capabilities`.
public struct AppCapabilities: Decodable, Sendable, Equatable {
    public var contract: String?
    public var version: Int?
    public var jobs: [Job]
    public var appID: String?
    /// The people this credential answers as.
    public var actors: [String]

    public struct Job: Decodable, Sendable, Equatable {
        public var id: String
        public var answerForms: [String]?
    }

    /// The contract and version this kit speaks, with its one job.
    public var supportsAnswering: Bool {
        contract == "openrig.core-app" && version == 1 && jobs.contains { $0.id == "human-answer" }
    }

    private enum CodingKeys: String, CodingKey { case contract, version, jobs, app }
    private enum AppKeys: String, CodingKey { case id, actors }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contract = c.lenient(String.self, .contract)
        version = c.lenient(Int.self, .version)
        jobs = c.lenient([Job].self, .jobs) ?? []
        let app = try? c.nestedContainer(keyedBy: AppKeys.self, forKey: .app)
        appID = app?.lenient(String.self, .id)
        actors = app?.lenient([String].self, .actors) ?? []
    }
}

/// Whether a source behind a read answered in full. `partial` and `unavailable` mean missing items are unknown, not
/// resolved.
public struct AppSource: Decodable, Sendable, Equatable {
    public var source: String
    public var state: String
    public var detail: String?
}

/// `GET /needs-me`: the person's current structured asks.
public struct AppNeedsMe: Decodable, Sendable, Equatable {
    public var requests: [AppRequest]
    public var sources: [AppSource]

    /// False when a source was partial or unavailable: an ask absent from `requests` may still be open.
    public var isComplete: Bool { !sources.isEmpty && sources.allSatisfy { $0.state == "available" } }

    private enum CodingKeys: String, CodingKey { case requests, sources }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = c.lenient([AppRequest].self, .requests) ?? []
        sources = c.lenient([AppSource].self, .sources) ?? []
    }
}

/// One ask, from needs-me or `GET /requests/:id`.
public struct AppRequest: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var asker: String?
    public var askedPerson: String?
    public var state: QItemState?
    /// Opaque. An answer must send back the one it was read with.
    public var decisionRevision: String?
    /// Null for a direct ask. Sent back as read, null included.
    public var episodeKey: String?
    public var body: String?
    public var humanDetail: String?
    public var questions: [HumanQuestion]
    /// Question id → the answer recorded so far.
    public var humanAnswers: [String: AppHumanAnswer]
    /// False when the contract can't answer this ask; `unsupportedReason` says why.
    public var isAnswerable: Bool
    public var unsupportedReason: String?
    /// The asking agent's seat can't be confirmed current. The ask can still be answered; no effect is implied.
    public var occupantAuthorityUnknown: Bool

    public var unansweredQuestions: [HumanQuestion] { questions.filter { humanAnswers[$0.id] == nil } }

    private enum CodingKeys: String, CodingKey {
        case requestId, asker, askedPerson, state, decisionRevision, episodeKey, body, humanDetail, questions
        case humanAnswers, answer, unsupportedReason, occupantAuthority
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .requestId)
        asker = c.lenient(String.self, .asker)
        askedPerson = c.lenient(String.self, .askedPerson)
        state = c.lenient(QItemState.self, .state)
        decisionRevision = c.lenient(String.self, .decisionRevision)
        episodeKey = c.lenient(String.self, .episodeKey)
        body = c.lenient(String.self, .body)
        humanDetail = c.lenient(String.self, .humanDetail)
        questions = c.lenient([HumanQuestion].self, .questions) ?? []
        // Each value on its own: one odd value must not drop the others.
        humanAnswers = (c.lenient([String: JSONValue].self, .humanAnswers) ?? [:]).compactMapValues(AppHumanAnswer.init)
        isAnswerable = c.lenient(JSONValue.self, .answer).map { $0 != .null } ?? false
        unsupportedReason = c.lenient(String.self, .unsupportedReason)
        occupantAuthorityUnknown = c.lenient(String.self, .occupantAuthority) == "unknown"
    }
}

/// One recorded answer. The daemon stores a choice as the option id and a typed reply as
/// `{kind: "typed-reply", text, placement, unansweredCount}`.
public enum AppHumanAnswer: Sendable, Equatable {
    case option(String)
    case typedReply(String)
    /// A shape this kit doesn't know. The daemon still counts the question as answered.
    case unrecognized

    /// Nil only for null, which the daemon treats as no answer.
    init?(_ value: JSONValue) {
        switch value {
        case .null: return nil
        case .string(let id): self = .option(id)
        case .object(let fields):
            if case .string(let text) = fields["text"], fields["kind"] == .string("typed-reply") {
                self = .typedReply(text)
            } else {
                self = .unrecognized
            }
        default: self = .unrecognized
        }
    }
}

/// `GET /requests/:id/result`: what actually happened to an ask, read separately from the answer's receipt.
public struct AppResult: Decodable, Sendable, Equatable {
    public var request: AppRequest?
    public var answerReturn: AnswerReturn?
    /// `not-applicable` unless the ask was a runner's permission request.
    public var permissionStatus: String?
    public var workStatus: String?
    public var sources: [AppSource]

    public struct AnswerReturn: Decodable, Sendable, Equatable {
        /// `returned`, `kept-for-agent`, `not-returned` or `unknown`.
        public var status: String
        public var replyQitemId: String?
        public var body: String?
    }

    /// False when the linked work could only be read in part.
    public var isComplete: Bool {
        !sources.isEmpty && sources.allSatisfy { $0.state == "available" } && workStatus != "partial"
    }

    private enum CodingKeys: String, CodingKey { case request, answerReturn, permissionDecision, work, sources }
    private enum StatusKeys: String, CodingKey { case status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = c.lenient(AppRequest.self, .request)
        answerReturn = c.lenient(AnswerReturn.self, .answerReturn)
        permissionStatus =
            (try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .permissionDecision))?.lenient(
                String.self, .status)
        workStatus = (try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .work))?.lenient(String.self, .status)
        sources = c.lenient([AppSource].self, .sources) ?? []
    }
}

public enum AppAnswerForm: Codable, Sendable, Equatable {
    case option(String)
    case typedReply(String)

    private enum CodingKeys: String, CodingKey { case kind, optionId, text }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "option": self = .option(try c.decode(String.self, forKey: .optionId))
        case "typed-reply": self = .typedReply(try c.decode(String.self, forKey: .text))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown answer kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .option(let id):
            try c.encode("option", forKey: .kind)
            try c.encode(id, forKey: .optionId)
        case .typedReply(let text):
            try c.encode("typed-reply", forKey: .kind)
            try c.encode(text, forKey: .text)
        }
    }
}

/// The exact body of `POST /answers/:id`. Save it with its answer id before sending, and resend it unchanged on a
/// retry: a changed binding under the same id is refused.
public struct AppAnswerBinding: Codable, Sendable, Equatable {
    public var job = "human-answer"
    public var actor: String
    public var requestId: String
    public var questionId: String
    public var episodeKey: String?
    public var expectedRevision: String
    public var answer: AppAnswerForm

    /// Typed replies the daemon accepts: at most 16 KiB of UTF-8 after trimming.
    public static let maxReplyBytes = 16 * 1024

    /// One option of one question. Nil when the request can't be answered or has no such option.
    public static func choosing(
        _ option: String, for question: String, in request: AppRequest, as actor: String
    ) -> AppAnswerBinding? {
        guard request.isAnswerable, let revision = request.decisionRevision,
            request.questions.first(where: { $0.id == question })?.options.contains(where: { $0.id == option }) == true
        else { return nil }
        return AppAnswerBinding(
            actor: actor, requestId: request.id, questionId: question, episodeKey: request.episodeKey,
            expectedRevision: revision, answer: .option(option))
    }

    /// The person's own words. They answer the whole ask, so the daemon files them under the first question still
    /// unanswered. Nil when there is none, or the text is blank, has a NUL or is too long.
    public static func replying(_ text: String, to request: AppRequest, as actor: String) -> AppAnswerBinding? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.isAnswerable, let revision = request.decisionRevision,
            let question = request.unansweredQuestions.first,
            !text.isEmpty, !text.contains("\0"), text.utf8.count <= maxReplyBytes
        else { return nil }
        return AppAnswerBinding(
            actor: actor, requestId: request.id, questionId: question.id, episodeKey: request.episodeKey,
            expectedRevision: revision, answer: .typedReply(text))
    }

    private enum CodingKeys: String, CodingKey {
        case job, actor, requestId, questionId, episodeKey, expectedRevision, answer
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(job, forKey: .job)
        try c.encode(actor, forKey: .actor)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(questionId, forKey: .questionId)
        // The daemon requires the key: a direct ask's episode is an explicit null.
        if let episodeKey {
            try c.encode(episodeKey, forKey: .episodeKey)
        } else {
            try c.encodeNil(forKey: .episodeKey)
        }
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(answer, forKey: .answer)
    }
}

public enum AppAnswerID {
    /// A fresh opaque id, within the daemon's rule of 8–128 letters, digits, `_` or `-`.
    public static func random() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// The reply to `POST /answers/:id`, or `GET /answers/:id`.
public struct AppAnswerReceipt: Decodable, Sendable, Equatable {
    public var answerID: String?
    /// True when this is the saved receipt of an earlier attempt with the same id.
    public var replayed: Bool
    public var submission: Submission
    /// Set on reads that didn't commit: whether resending the same id and binding may finish it.
    public var retrySameSubmission: Bool?
    public var currentRevision: String?

    public struct Submission: Decodable, Sendable, Equatable {
        /// `committed`, `incomplete`, `conflict` or `source_unavailable`.
        public var state: String
        /// `recorded` (a partial choice) or `answered`.
        public var outcome: String?
        /// The text of the questions still open, not their ids. For ids, read the request's `unansweredQuestions`.
        public var unansweredText: [String]
        public var message: String?
        public var replyQitemId: String?
        public var conflictCode: String?

        private enum CodingKeys: String, CodingKey {
            case state, outcome, unanswered, message, replyQitemId, conflictCode
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = c.lenient(String.self, .state) ?? "unknown"
            outcome = c.lenient(String.self, .outcome)
            unansweredText = c.lenient([String].self, .unanswered) ?? []
            message = c.lenient(String.self, .message)
            replyQitemId = c.lenient(String.self, .replyQitemId)
            conflictCode = c.lenient(String.self, .conflictCode)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case answerId, replayed, submission, retrySameSubmission, currentRevision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerID = c.lenient(String.self, .answerId)
        replayed = c.lenient(Bool.self, .replayed) ?? false
        submission = try c.decode(Submission.self, forKey: .submission)
        retrySameSubmission = c.lenient(Bool.self, .retrySameSubmission)
        currentRevision = c.lenient(String.self, .currentRevision)
    }

    /// What the receipt says happened, read as core-app.md says: the reply row first, then the message.
    /// `answered` never proves an effect: not that permission was granted or work done.
    public var fate: AppAnswerFate {
        switch submission.state {
        case "committed":
            if submission.outcome == "recorded" { return .partial(unansweredText: submission.unansweredText) }
            guard let reply = submission.replyQitemId else { return .answeredInPlace(message: submission.message) }
            return submission.message?.hasPrefix("Already answered") == true
                ? .alreadyAnswered(reply: reply) : .returned(reply: reply)
        case "incomplete": return .incomplete
        case "conflict": return .conflict(submission.conflictCode ?? "conflict")
        case "source_unavailable": return .sourceUnavailable
        default: return .unknown(submission.state)
        }
    }
}

public enum AppAnswerFate: Sendable, Equatable {
    /// One choice saved; the questions with this text are still open.
    case partial(unansweredText: [String])
    /// Returned to the asker as this new row.
    case returned(reply: String)
    /// Someone answered first; `reply` is that original return. Nothing new was sent.
    case alreadyAnswered(reply: String)
    /// A runner's permission request, answered on the request itself. The message says whether its agent got the
    /// answer or it is kept until one can read it.
    case answeredInPlace(message: String?)
    /// Reserved but not finished: resend the same id and binding.
    case incomplete
    /// Can't be finished as sent (e.g. the ask changed). Needs the person's new decision.
    case conflict(String)
    /// The ask's content was erased.
    case sourceUnavailable
    case unknown(String)
}

/// `POST /api/apps/v1/credentials`: the app's own credential. The token is shown once and never logged.
public struct AppCredential: Decodable, Sendable, Equatable, Identifiable {
    /// The app id every phone's credential is issued under. Each phone gets its own credential.
    public static let remoteAppID = "openrig-remote"

    public var id: String
    public var appID: String
    public var token: String
    public var actors: [String]

    private enum CodingKeys: String, CodingKey { case credentialId, appId, token, scope }
    private enum ScopeKeys: String, CodingKey { case actors }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .credentialId)
        token = try c.decode(String.self, forKey: .token)
        appID = c.lenient(String.self, .appId) ?? ""
        let scope = try? c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        actors = scope?.lenient([String].self, .actors) ?? []
    }
}

/// Leaves the token out of `print`, `debugPrint` and `dump`.
extension AppCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AppCredential(\(id), \(appID), \(actors.joined(separator: ", ")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "appID": appID, "actors": actors]) }
}

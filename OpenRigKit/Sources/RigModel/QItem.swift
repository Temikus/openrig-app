import Foundation

/// One queue row, from `GET /api/queue/list` or `GET /api/queue/:id`.
public struct QItem: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    /// Session that created it, e.g. `orch-lead@denkeeper`.
    public var source: String
    /// Session that owns it.
    public var destination: String
    public var state: QItemState
    public var priority: String?
    public var summary: String
    public var body: String?
    public var tags: [String]
    /// What it waits on: a qitem id, or a free-form ref such as `external:person-decision-pr602`.
    public var blockedOn: String?
    /// The predecessor qitem id when this item was created by `rig queue handoff`.
    public var handedOffFrom: String?
    /// The session this item was handed to. A session, not a qitem id.
    public var handedOffTo: String?
    public var closureReason: String?
    public var closureTarget: String?
    public var closeBy: Date?
    public var claimedAt: Date?
    public var created: Date?
    public var updated: Date?
    /// Ancestor qitem ids, oldest first, ending with the direct predecessor. Nil when not a handoff.
    public var chainOfRecord: [String]?
    public var resolution: String?
    /// True when the row carries questions for a human.
    public var asksHuman: Bool
    /// The questions, each with 2–4 options, when the asker gave fixed choices.
    public var humanQuestions: [HumanQuestion] = []
    /// Answers recorded so far, by question id. Any recorded value counts as answered, as it does for the daemon.
    public var humanAnswers: [String: HumanAnswer] = [:]
    /// For a row to a person: `decision` (the daemon's default) or `update`, an FYI.
    public var humanIntent: String?
    /// The artifact a person is asked to judge; required on every row to a person.
    public var evidenceRef: String?

    public init(
        id: String, source: String, destination: String, state: QItemState, priority: String? = nil,
        summary: String = "", body: String? = nil, tags: [String] = [], blockedOn: String? = nil,
        handedOffFrom: String? = nil, handedOffTo: String? = nil, closureReason: String? = nil,
        closureTarget: String? = nil, closeBy: Date? = nil, claimedAt: Date? = nil, created: Date? = nil,
        updated: Date? = nil, chainOfRecord: [String]? = nil, resolution: String? = nil, asksHuman: Bool = false,
        humanIntent: String? = nil, evidenceRef: String? = nil
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.state = state
        self.priority = priority
        self.summary = summary
        self.body = body
        self.tags = tags
        self.blockedOn = blockedOn
        self.handedOffFrom = handedOffFrom
        self.handedOffTo = handedOffTo
        self.closureReason = closureReason
        self.closureTarget = closureTarget
        self.closeBy = closeBy
        self.claimedAt = claimedAt
        self.created = created
        self.updated = updated
        self.chainOfRecord = chainOfRecord
        self.resolution = resolution
        self.asksHuman = asksHuman
        self.humanIntent = humanIntent
        self.evidenceRef = evidenceRef
    }

    private enum CodingKeys: String, CodingKey {
        case qitemId, sourceSession, destinationSession, state, priority, summary, body, tags, blockedOn
        case handedOffFrom, handedOffTo, closureReason, closureTarget, closureRequiredAt, claimedAt
        case tsCreated, tsUpdated, chainOfRecord, resolution, humanQuestions, humanAnswers, humanIntent, evidenceRef
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .qitemId)
        source = c.lenient(String.self, .sourceSession) ?? ""
        destination = c.lenient(String.self, .destinationSession) ?? ""
        state = c.lenient(QItemState.self, .state) ?? QItemState(rawValue: "unknown")
        priority = c.lenient(String.self, .priority)
        body = c.lenient(String.self, .body)
        // Workflow packets have no summary; their body opens with a "### Workflow entry: …" heading.
        summary =
            c.lenient(String.self, .summary)
            ?? body?.split(separator: "\n").lazy
            .map { $0.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        tags = c.lenient([String].self, .tags) ?? []
        blockedOn = c.lenient(String.self, .blockedOn)
        handedOffFrom = c.lenient(String.self, .handedOffFrom)
        handedOffTo = c.lenient(String.self, .handedOffTo)
        closureReason = c.lenient(String.self, .closureReason)
        closureTarget = c.lenient(String.self, .closureTarget)
        closeBy = c.lenient(String.self, .closureRequiredAt).flatMap(parseDaemonDate)
        claimedAt = c.lenient(String.self, .claimedAt).flatMap(parseDaemonDate)
        created = c.lenient(String.self, .tsCreated).flatMap(parseDaemonDate)
        updated = c.lenient(String.self, .tsUpdated).flatMap(parseDaemonDate)
        chainOfRecord = c.lenient([String].self, .chainOfRecord)
        resolution = c.lenient(String.self, .resolution)
        humanIntent = c.lenient(String.self, .humanIntent)
        evidenceRef = c.lenient(String.self, .evidenceRef)
        humanQuestions = c.lenient([HumanQuestion].self, .humanQuestions) ?? []
        // Each value on its own: one typed reply (an object) must not drop the row's other answers.
        humanAnswers = (c.lenient([String: JSONValue].self, .humanAnswers) ?? [:]).compactMapValues(HumanAnswer.init)
        // Any non-null, non-empty value counts, even one whose shape didn't decode.
        if let questions = c.lenient([JSONValue].self, .humanQuestions) {
            asksHuman = !questions.isEmpty
        } else {
            asksHuman = c.lenient(JSONValue.self, .humanQuestions).map { $0 != .null } ?? false
        }
    }
}

/// One recorded answer. The daemon stores a choice as the option id and a typed reply as
/// `{kind: "typed-reply", text, placement, unansweredCount}` (queue-repository.js `placeTypedReply`).
public enum HumanAnswer: Sendable, Hashable, ExpressibleByStringLiteral {
    case option(String)
    case typedReply(String)
    /// A shape this app doesn't know. The daemon still counts the question as answered.
    case unrecognized

    public init(stringLiteral id: String) { self = .option(id) }

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

    /// What to show for it: the option's label, or the person's own words.
    public func text(in question: HumanQuestion) -> String {
        switch self {
        case .option(let id): question.options.first { $0.id == id }?.label ?? id
        case .typedReply(let text): text
        case .unrecognized: "An answer this app can't show"
        }
    }
}

/// A question with fixed choices, as `rig queue create --human-questions-file` takes it.
public struct HumanQuestion: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var question: String
    public var options: [Option]

    public struct Option: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        /// The asker's suggestion; at most one per question.
        public var recommended: Bool?

        public init(id: String, label: String, recommended: Bool? = nil) {
            self.id = id
            self.label = label
            self.recommended = recommended
        }
    }

    public init(id: String, question: String, options: [Option]) {
        self.id = id
        self.question = question
        self.options = options
    }
}

public struct QItemState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending = QItemState(rawValue: "pending")
    public static let inProgress = QItemState(rawValue: "in-progress")
    public static let blocked = QItemState(rawValue: "blocked")
    public static let done = QItemState(rawValue: "done")
    public static let handedOff = QItemState(rawValue: "handed-off")
    /// Terminal, e.g. the open packets of an aborted workflow.
    public static let canceled = QItemState(rawValue: "canceled")
}

/// Any JSON value, for fields whose shape we only need to test for presence.
public enum JSONValue: Decodable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
}

import RigModel

/// The person's answer to a row an agent sent them. Closing only records it on the row; a message is what tells
/// the asker, so approve and deny send one first by default.
public struct Answer: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case approve, deny
        /// A question the person answered in their own words, by message.
        case answered
        /// An update read; nothing follows.
        case acknowledge
    }

    public var verdict: Verdict
    public var note: String
    /// Message the asker. Only approve and deny tell; the others never send.
    public var tell: Bool
    /// For `answered`: a reply went out from the app, so the row can say so.
    public var replied: Bool

    public init(_ verdict: Verdict, note: String = "", tell: Bool = true, replied: Bool = false) {
        self.verdict = verdict
        self.note = note
        self.tell = tell
        self.replied = replied
    }

    private var verb: String? {
        switch verdict {
        case .approve: "Approved"
        case .deny: "Denied"
        case .answered, .acknowledge: nil
        }
    }

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The message to the asker, or nil when this answer tells no one. `replacing` is an earlier, different
    /// answer already sent, so the agent knows this one supersedes it.
    public func message(for item: QItem, replacing earlier: RigAction? = nil) -> RigAction? {
        guard tell, let verb else { return nil }
        var text = "\(verb): \(item.summary) (\(item.id))"
        if let earlier, earlier != message(for: item) { text = "Changed: " + text }
        if !trimmed.isEmpty {
            text += "\n\(trimmed)"
        } else if verdict == .deny {
            // A bare no leaves the agent guessing; this keeps it from retrying blind.
            text += "\nNo reason given; ask before retrying."
        }
        return .send(session: item.source, text: text)
    }

    /// The close. Its resolution records whether the asker was told, for anyone reading the row later.
    public func close(_ item: QItem, told: Bool) -> RigAction {
        let resolution: String? =
            switch verdict {
            case .answered: replied ? "Answered by message" : "Closed without a reply from the app"
            case .acknowledge: trimmed.isEmpty ? nil : "Noted: \(trimmed)"
            case .approve, .deny:
                [verb ?? "", told ? "told \(Self.seatName(item.source))" : nil].compactMap(\.self)
                    .joined(separator: " · ") + (trimmed.isEmpty ? "" : ": \(trimmed)")
            }
        return .close(
            id: item.id, reason: verdict == .deny ? .denied : .noFollowOn, target: nil, resolution: resolution)
    }

    /// The line shown once the row closes, e.g. "Approved · orch-lead told".
    public func outcome(asker: String, told: Bool) -> String {
        [verb ?? "Closed", told ? "\(asker) told" : nil].compactMap(\.self).joined(separator: " · ")
    }

    private static func seatName(_ session: String) -> String {
        session.split(separator: "@").first.map(String.init) ?? session
    }

    public struct Result: Sendable, Equatable {
        /// The answer the asker has, as `message(for:)` (without any "Changed:" mark), from this run or an earlier
        /// one; nil when nobody was told. Pass it back as `alreadySent` on a retry.
        public var sent: RigAction?
        public var closed: Bool
        public var told: Bool { sent != nil }
    }

    /// Tells the asker, then closes. A failed message stops before the close, leaving the row open.
    /// `alreadySent` is the `message(for:)` an earlier run sent before its close failed: the same answer isn't
    /// sent twice, and a different one goes out marked as a change. Either way the row records the asker as told.
    public func run(
        on item: QItem, alreadySent: RigAction? = nil, isolation: isolated (any Actor)? = #isolation,
        perform: (RigAction) async -> Bool
    ) async -> Result {
        let fresh = message(for: item)
        if let fresh, fresh != alreadySent {
            let wire = message(for: item, replacing: alreadySent) ?? fresh
            guard await perform(wire) else { return Result(sent: alreadySent, closed: false) }
        }
        let sent = fresh ?? alreadySent
        let closed = await perform(close(item, told: sent != nil))
        return Result(sent: sent, closed: closed)
    }
}

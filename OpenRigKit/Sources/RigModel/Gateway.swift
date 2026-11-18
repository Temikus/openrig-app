import Foundation

/// `GET /api/gateway/participants`: the people and shared channels the gateway knows, and the default person.
public struct GatewayParticipants: Decodable, Sendable, Equatable {
    public struct Participant: Decodable, Sendable, Equatable {
        public var id: String
        public var address: String
        public var kind: String
    }

    public var participants: [Participant]
    public var defaultID: String?

    public init(participants: [Participant] = [], defaultID: String? = nil) {
        self.participants = participants
        self.defaultID = defaultID
    }

    private enum CodingKeys: String, CodingKey { case participants, `default` }
    private struct Default: Decodable { var id: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participants = c.lenient([Participant].self, .participants) ?? []
        defaultID = c.lenient(Default.self, .default)?.id
    }

    /// The default person's address, as agents are told to reply to it.
    public var defaultAddress: String? {
        guard let defaultID else { return nil }
        return participants.first { $0.id == defaultID }?.address ?? "\(defaultID)@external"
    }
}

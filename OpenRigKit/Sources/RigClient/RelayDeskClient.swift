import Foundation

/// Why a Mac-side call through the relay didn't do what was asked.
public enum RelayDeskError: Error, Equatable, Sendable {
    /// The row isn't open and waiting on the person.
    case notForYou
    /// Nothing waits on that seat any more (answered here, on the Mac, or in the terminal).
    case promptGone
    /// Another prompt is up: a different command, or the same one asked again. Nothing was typed.
    case promptChanged
    /// The Mac can't read the prompt's plain Yes, or its No, on screen; answer in the terminal.
    case cannotAllowOnce
    case cannotDecline
    /// The seat is stopped at a permission prompt, so it can't take a message.
    case targetNeedsInput
    /// The Mac acts as someone other than this phone's person; pair again.
    case actorMismatch(String)
    case notFound(String)
    /// The Mac doesn't offer this call.
    case refused
    case failed(String)
    /// No reply came, and nothing was sent: the Mac couldn't be reached.
    case unreachable(String)
    /// The call went out but its reply was lost. It may have been done; it isn't sent again.
    case lostReply
    case decoding(String)
}

/// The phone's client for the relay's Mac-side calls (`RelayCall`): Needs you, prompts, answers to rows, messages,
/// tasks, rigs and seats. One call at a time over one channel, opened again when it drops.
///
/// Retries: a read is asked again once on a new channel if the old one drops. An acting call isn't, since a lost
/// reply may mean it ran: the phone hears `lostReply`. Allow once and decline are the exception and are resent once,
/// because the Mac checks the stop's `observedAt`: if the first went through, the resend finds the stop gone or
/// changed and types nothing, and the phone hears `promptGone` or `promptChanged`.
public actor RelayDeskClient {
    public typealias Open = @Sendable () async throws -> RelayChannel

    private let open: Open
    private var channel: RelayChannel?

    /// `open` makes and opens a new channel, e.g. to the next reach in the pairing code.
    public init(open: @escaping Open) {
        self.open = open
    }

    // MARK: Reads

    public func needsYou() async throws(RelayDeskError) -> RelayNeedsYou {
        try await decode(get("/relay/v1/needs-you"))
    }

    public func prompt(session: String) async throws(RelayDeskError) -> RelayPrompt {
        try await decode(get("/relay/v1/prompts/\(session)"))
    }

    public func rigs() async throws(RelayDeskError) -> [RelayRig] {
        try await decode(get("/relay/v1/rigs"))
    }

    public func seats(rig: String) async throws(RelayDeskError) -> [RelaySeat] {
        try await decode(get("/relay/v1/rigs/\(rig)/seats"))
    }

    // MARK: Acting

    public func allowOnce(_ prompt: RelayPrompt) async throws(RelayDeskError) {
        try await post(
            "/relay/v1/prompts/\(prompt.session)/allow-once",
            ["command": prompt.command, "observedAt": prompt.observedAt], resend: true)
    }

    public func decline(_ prompt: RelayPrompt, reason: String) async throws(RelayDeskError) {
        try await post(
            "/relay/v1/prompts/\(prompt.session)/decline",
            ["command": prompt.command, "observedAt": prompt.observedAt, "reason": reason], resend: true)
    }

    public func reply(row: String, text: String) async throws(RelayDeskError) {
        try await post("/relay/v1/rows/\(row)/reply", ["text": text])
    }

    public func gotIt(row: String) async throws(RelayDeskError) {
        try await post("/relay/v1/rows/\(row)/got-it", [:])
    }

    public func done(row: String, replied: Bool) async throws(RelayDeskError) {
        try await post("/relay/v1/rows/\(row)/done", ["replied": replied])
    }

    public func message(session: String, text: String) async throws(RelayDeskError) {
        try await post("/relay/v1/seats/\(session)/message", ["text": text])
    }

    public func task(session: String, summary: String, body: String) async throws(RelayDeskError) {
        try await post("/relay/v1/seats/\(session)/task", ["summary": summary, "body": body])
    }

    // MARK: Transport

    private func get(_ path: String) async throws(RelayDeskError) -> RelayResponse {
        let request = RelayRequest(method: "GET", path: path)
        do {
            return try await send(request)
        } catch .lostReply {
            return try await send(request)  // a read changes nothing: ask again on a new channel
        }
    }

    private func post(_ path: String, _ body: [String: any Sendable], resend: Bool = false) async throws(RelayDeskError)
    {
        let request = RelayRequest(
            method: "POST", path: path, headers: ["Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body))
        let response: RelayResponse
        do {
            response = try await send(request)
        } catch .lostReply where resend {
            response = try await send(request)
        }
        try check(response)
    }

    /// One call. `unreachable` when no channel could be opened (nothing was sent); `lostReply` when the channel failed
    /// after sending.
    private func send(_ request: RelayRequest) async throws(RelayDeskError) -> RelayResponse {
        let channel: RelayChannel
        if let open = self.channel {
            channel = open
        } else {
            do {
                channel = try await open()
            } catch {
                throw .unreachable("\(error)")
            }
            self.channel = channel
        }
        do {
            guard let response = try await channel.call(request).last else { throw RelayLinkError.closed }
            return response
        } catch {
            channel.close()
            self.channel = nil
            throw .lostReply
        }
    }

    private func decode<T: Decodable>(_ response: RelayResponse) throws(RelayDeskError) -> T {
        try check(response)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw .decoding("\(error)")
        }
    }

    private func check(_ response: RelayResponse) throws(RelayDeskError) {
        guard !(200..<300).contains(response.status) else { return }
        let body = try? JSONDecoder().decode([String: String].self, from: response.body)
        let message = body?["message"] ?? ""
        switch body?["error"] {
        case "not_for_you": throw .notForYou
        case "prompt_gone": throw .promptGone
        case "prompt_changed": throw .promptChanged
        case "cannot_allow_once": throw .cannotAllowOnce
        case "cannot_decline": throw .cannotDecline
        case "target_needs_input": throw .targetNeedsInput
        case "actor_mismatch": throw .actorMismatch(message)
        case "no_such_row", "no_such_rig": throw .notFound(message)
        case "failed": throw .failed(message)
        default:
            if response.status == 403 { throw .refused }
            throw .failed(message.isEmpty ? "HTTP \(response.status)" : message)
        }
    }
}

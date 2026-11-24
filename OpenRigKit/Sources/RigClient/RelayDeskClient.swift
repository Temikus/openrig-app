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
    /// Allow once or decline lost its reply, and the resend found the prompt gone: the first almost surely went
    /// through.
    case probablyAnswered
    /// As above, but a new prompt is up now: show it.
    case answeredThenNewPrompt
    /// A read whose task was cancelled while it waited its turn; it never went out.
    case cancelled
    case decoding(String)
}

/// The phone's client for the relay's Mac-side calls (`RelayCall`): Needs you, prompts, answers to rows, messages,
/// tasks, rigs and seats. One call at a time over one channel, opened again when it drops.
///
/// Retries:
/// - Nothing sent (no channel, a channel that died while idle, a send that failed): any call is tried once more on a
///   new channel.
/// - A read whose reply was lost is asked again once.
/// - An acting call whose reply was lost isn't resent, since it may have run: the phone hears `lostReply`.
/// - Allow once and decline are the exception and are resent once, because the Mac checks the stop's `observedAt`:
///   if the first went through, the resend finds the stop gone or changed and types nothing. The phone hears
///   `probablyAnswered`, or `answeredThenNewPrompt` when another prompt is up.
///
/// Each call has `timeout` (15 s, longer than the Mac's ~5 s wait for a declined prompt to clear). A call that runs
/// out closes its channel, so one silent Mac doesn't hold every call behind it. A read cancelled while it waits its
/// turn is skipped (`cancelled`); an acting call still runs, since the person tapped it.
public actor RelayDeskClient {
    public typealias Open = @Sendable () async throws -> RelayChannel

    private let open: Open
    private let timeout: Duration
    private var channel: RelayChannel?
    /// Set by `close()`: nothing opens or goes out after it.
    private var closed = false
    /// One call at a time through the whole open-and-call: the actor alone would let a second call in at every await.
    private let serial = AsyncSerial()

    /// `open` makes and opens a new channel, e.g. to the next reach in the pairing code.
    public init(timeout: Duration = .seconds(15), open: @escaping Open) {
        self.timeout = timeout
        self.open = open
    }

    /// Stops this client, e.g. when another pairing or address replaces it. Its channel closes now, so a call in
    /// flight ends at once (`lostReply` if it had gone out). Every later call fails as `unreachable("closed")` without
    /// opening a channel or sending. Runs beside the serial gate, not in it, so it never waits on a stuck call.
    public func close() {
        closed = true
        channel?.close()
        channel = nil
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
        switch await send(request, skipIfCancelled: true) {
        case .success(let response): return response
        // A read changes nothing: ask again on a new channel, whatever was lost.
        case .failure(.lostReply), .failure(.unreachable): return try await send(request, skipIfCancelled: true).get()
        case .failure(let error): throw error
        }
    }

    private func post(_ path: String, _ body: [String: any Sendable], resend: Bool = false) async throws(RelayDeskError)
    {
        let request = RelayRequest(
            method: "POST", path: path, headers: ["Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body))
        var result = await send(request)
        var resent = false
        switch result {
        case .failure(.unreachable):
            result = await send(request)  // nothing was sent: safe for any call
        case .failure(.lostReply) where resend:
            result = await send(request)
            resent = true
        default: break
        }
        do {
            try check(try result.get())
        } catch .promptGone where resent {
            throw .probablyAnswered
        } catch .promptChanged where resent {
            throw .answeredThenNewPrompt
        }
    }

    /// One call, one at a time. `unreachable` when nothing was sent (no channel, the send failed, or time ran out
    /// before it went); `lostReply` when the reply was lost or late after the send went out.
    private func send(_ request: RelayRequest, skipIfCancelled: Bool = false) async -> Result<
        RelayResponse, RelayDeskError
    > {
        await serial.run {
            if skipIfCancelled, Task.isCancelled { return .failure(.cancelled) }
            return await attempt(request)
        }
    }

    private func attempt(_ request: RelayRequest) async -> Result<RelayResponse, RelayDeskError> {
        guard !closed else { return .failure(.unreachable("closed")) }
        if let idle = channel, !idle.isReady {
            idle.close()
            channel = nil
        }
        let channel: RelayChannel
        if let open = self.channel {
            channel = open
        } else {
            do {
                channel = try await open()
            } catch {
                return .failure(.unreachable("\(error)"))
            }
            // close() may have run while this one opened: don't keep or use it.
            guard !closed else {
                channel.close()
                return .failure(.unreachable("closed"))
            }
            self.channel = channel
        }
        do {
            guard let response = try await channel.call(request, timeout: timeout).last else {
                throw RelayLinkError.closed
            }
            return .success(response)
        } catch {
            channel.close()
            self.channel = nil
            switch error {
            case RelayLinkError.notSent(let why): return .failure(.unreachable(why))
            case RelayLinkError.timedOut(afterSend: false): return .failure(.unreachable("timed out before sending"))
            default: return .failure(.lostReply)
            }
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

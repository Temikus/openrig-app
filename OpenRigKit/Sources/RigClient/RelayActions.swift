import Foundation
import RigModel

/// What the phone may ask the Mac to show or do through the relay, beyond the app contract. A fixed list: anything
/// else is refused. "Always allow" isn't on it; standing permissions stay on the Mac.
public enum RelayCall: Equatable, Sendable {
    case needsYou
    case prompt(session: String)
    /// `observedAt` is the stop's time as `RelayPrompt` gave it, so the same command asked again is a new prompt.
    case allowOnce(session: String, command: String, observedAt: String)
    case decline(session: String, command: String, observedAt: String, reason: String)
    case reply(row: String, text: String)
    case gotIt(row: String)
    case done(row: String, replied: Bool)
    case message(session: String, text: String)
    case task(session: String, summary: String, body: String)
    case rigs
    case seats(rig: String)

    static let prefix = "/relay/v1/"

    /// Nil for any call not on the list, or with a missing or blank field.
    public init?(_ request: RelayRequest) {
        guard request.path.hasPrefix(Self.prefix), let parts = URLComponents(string: request.path),
            parts.scheme == nil, parts.host == nil, parts.query == nil,
            let path = parts.percentEncodedPath.removingPercentEncoding, path.hasPrefix(Self.prefix)
        else { return nil }
        let s = path.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(
            String.init)
        let body = (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        func text(_ key: String) -> String? {
            (body[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        guard s.allSatisfy(Self.isSegment) else { return nil }
        switch (request.method, s.count, s.first) {
        case ("GET", 1, "needs-you"): self = .needsYou
        case ("GET", 1, "rigs"): self = .rigs
        case ("GET", 3, "rigs") where s[2] == "seats": self = .seats(rig: s[1])
        case ("GET", 2, "prompts"): self = .prompt(session: s[1])
        case ("POST", 3, "prompts"):
            // Both required; `observedAt` may be "" when the daemon gave no time, but not missing.
            guard let command = body["command"] as? String, !command.isEmpty,
                let observedAt = body["observedAt"] as? String
            else { return nil }
            switch s[2] {
            case "allow-once": self = .allowOnce(session: s[1], command: command, observedAt: observedAt)
            case "decline":
                self = .decline(session: s[1], command: command, observedAt: observedAt, reason: text("reason") ?? "")
            default: return nil
            }
        case ("POST", 3, "rows"):
            switch s[2] {
            case "reply":
                guard let words = text("text") else { return nil }
                self = .reply(row: s[1], text: words)
            case "got-it": self = .gotIt(row: s[1])
            case "done": self = .done(row: s[1], replied: body["replied"] as? Bool ?? false)
            default: return nil
            }
        case ("POST", 3, "seats"):
            switch s[2] {
            case "message":
                guard let words = text("text") else { return nil }
                self = .message(session: s[1], text: words)
            case "task":
                guard let summary = text("summary") else { return nil }
                self = .task(session: s[1], summary: summary, body: text("body") ?? "")
            default: return nil
            }
        default: return nil
        }
    }

    /// Changes something: an answer, a message, a task. Reads don't.
    var acts: Bool {
        switch self {
        case .needsYou, .prompt, .rigs, .seats: false
        default: true
        }
    }

    /// A name, row id or session: letters, digits, "-", "_", ".", ":" and "@"; never "." or "..".
    static func isSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".."
            && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:@".contains($0)) }
    }
}

/// A seat's permission prompt as the Mac reads it right now: the daemon's stop and the pane together.
public struct RelayPromptReading: Sendable, Equatable {
    public var session: String
    public var seatName: String
    public var command: String
    /// When the daemon saw the stop, as text; "" when it gave none. With the command, it tells one prompt from the
    /// same command asked again, as `PromptInstance.check(against:)` does on the Mac.
    public var observedAt: String
    /// The menu's own plain Yes, found by its label; nil when the pane can't be read.
    public var allowOnceKey: String?
    public var declineKey: String?

    public init(
        session: String, seatName: String, command: String, observedAt: String, allowOnceKey: String?,
        declineKey: String?
    ) {
        self.session = session
        self.seatName = seatName
        self.command = command
        self.observedAt = observedAt
        self.allowOnceKey = allowOnceKey
        self.declineKey = declineKey
    }
}

/// What the phone gets for one prompt. Allow once and decline send `command` and `observedAt` back.
public struct RelayPrompt: Codable, Sendable, Equatable {
    public var session: String
    public var seat: String
    /// In full: a shortened command could hide the risky part.
    public var command: String
    public var observedAt: String
    public var canAllowOnce: Bool
    public var canDecline: Bool
}

/// One row of the Mac's Needs-you list.
public struct RelayNeedsYouItem: Codable, Sendable, Equatable {
    /// "ask", "prompt", "fyi", "held" or "seat".
    public var kind: String
    public var id: String
    public var rig: String
    public var title: String
    public var detail: String?
    public var session: String?
    public var row: String?

    public init(
        kind: String, id: String, rig: String, title: String, detail: String? = nil, session: String? = nil,
        row: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.rig = rig
        self.title = title
        self.detail = detail
        self.session = session
        self.row = row
    }
}

public struct RelayRig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// "running", "degraded", "stopped" or the daemon's own word.
    public var state: String
    public var seats: Int

    public init(id: String, name: String, state: String, seats: Int) {
        self.id = id
        self.name = name
        self.state = state
        self.seats = seats
    }
}

/// What the phone's seat screen shows.
public struct RelaySeat: Codable, Sendable, Equatable {
    public var session: String
    public var name: String
    public var state: String
    public var currentRow: String?
    public var active: Int
    public var blocked: Int
    /// 0…1, when the daemon reports it.
    public var contextUsed: Double?
    public var runtime: String?
    /// Stopped at a permission prompt: a message is refused until it's answered.
    public var atPrompt: Bool

    public init(
        session: String, name: String, state: String, currentRow: String?, active: Int, blocked: Int,
        contextUsed: Double?, runtime: String?, atPrompt: Bool
    ) {
        self.session = session
        self.name = name
        self.state = state
        self.currentRow = currentRow
        self.active = active
        self.blocked = blocked
        self.contextUsed = contextUsed
        self.runtime = runtime
        self.atPrompt = atPrompt
    }
}

public enum RelayOutcome: Sendable, Equatable {
    case done
    case failed(String)
}

/// The Mac's side of the relay's actions: reads what the Mac app already knows and runs its existing actions. The
/// seam tests replace, so no test reaches a daemon or a seat.
public protocol RelayDesk: Sendable {
    func needsYou() async -> [RelayNeedsYouItem]
    func prompt(session: String) async -> RelayPromptReading?
    /// After a decline: waits briefly for the pane to show no prompt, and says whether the daemon still holds one.
    func waitForNoPrompt(session: String) async -> (paneClear: Bool, daemonHolds: Bool)
    /// The seat's row parked on a person, which answering the prompt resolves.
    func heldRow(session: String) async -> String?
    /// Open and waiting on the Mac's person, as the Mac's Needs you lists it (`forYou`): only these may be answered.
    func isForPerson(_ row: QItem) async -> Bool
    /// Why the Mac won't act for the phone now (its person differs from the pairing's), or nil.
    func refusesActing() async -> String?
    func row(_ id: String) async -> QItem?
    func rigs() async -> [RelayRig]
    func seats(rig: String) async -> [RelaySeat]?
    func perform(_ action: RigAction) async -> RelayOutcome
}

/// Turns a phone's call into the Mac app's own actions, with the same checks the Mac's controls make.
public enum RelayActions {
    public static func handle(_ call: RelayCall, desk: some RelayDesk) async -> RelayResponse {
        if call.acts, let why = await desk.refusesActing() { return error(403, "actor_mismatch", why) }
        switch call {
        case .needsYou: return json(await desk.needsYou())
        case .rigs: return json(await desk.rigs())
        case .seats(let rig):
            guard let seats = await desk.seats(rig: rig) else { return error(404, "no_such_rig", "No rig \(rig).") }
            return json(seats)
        case .prompt(let session):
            guard let reading = await desk.prompt(session: session) else {
                return error(404, "prompt_gone", "Nothing is waiting on this seat.")
            }
            return json(
                RelayPrompt(
                    session: session, seat: reading.seatName, command: reading.command,
                    observedAt: reading.observedAt, canAllowOnce: reading.allowOnceKey != nil,
                    canDecline: reading.declineKey != nil))
        case .allowOnce(let session, let command, let observedAt):
            switch await same(session, command, observedAt, desk) {
            case .failure(let refused): return refused.response
            case .success(let reading):
                guard let yes = reading.allowOnceKey else {
                    return error(409, "cannot_allow_once", "The Mac can't read a plain Yes on screen.")
                }
                let outcome = await desk.perform(
                    .answerPrompt(session: session, keys: yes, reason: "OpenRig phone: allow once \(command)"))
                guard outcome == .done else { return failure(outcome) }
                await resolveHeld(session, "allow once: \(command)", desk)
                return ok()
            }
        case .decline(let session, let command, let observedAt, let reason):
            switch await same(session, command, observedAt, desk) {
            case .failure(let refused): return refused.response
            case .success(let reading):
                guard let no = reading.declineKey else {
                    return error(409, "cannot_decline", "The Mac can't read the prompt's No on screen.")
                }
                let outcome = await desk.perform(
                    .answerPrompt(session: session, keys: no, reason: "OpenRig phone: decline \(command)"))
                guard outcome == .done else { return failure(outcome) }
                if !reason.isEmpty {
                    // The decline sends no hook, so the daemon keeps the prompt and `rig send` refuses: as on the Mac,
                    // wait for the pane to clear, record that, then send the reason.
                    let after = await desk.waitForNoPrompt(session: session)
                    guard after.paneClear else {
                        return error(409, "prompt_changed", "Declined, but another prompt came up: reason not sent.")
                    }
                    if after.daemonHolds {
                        _ = await desk.perform(
                            .clearAttention(
                                session: session, reason: "OpenRig phone: prompt declined; the pane shows no prompt"))
                    }
                    let sent = await desk.perform(.send(session: session, text: reason))
                    guard sent == .done else { return failure(sent) }
                }
                await resolveHeld(
                    session, reason.isEmpty ? "declined: \(command)" : "declined: \(command); redirect: \(reason)", desk
                )
                return ok()
            }
        case .reply(let id, let text):
            switch await forPerson(id, desk) {
            case .failure(let refused): return refused.response
            case .success(let row): return result(await desk.perform(.send(session: row.source, text: text)))
            }
        case .gotIt(let id):
            switch await forPerson(id, desk) {
            case .failure(let refused): return refused.response
            case .success(let row): return result(await desk.perform(Answer(.acknowledge).close(row, told: false)))
            }
        case .done(let id, let replied):
            switch await forPerson(id, desk) {
            case .failure(let refused): return refused.response
            case .success(let row):
                return result(await desk.perform(Answer(.answered, replied: replied).close(row, told: false)))
            }
        case .message(let session, let text):
            return result(await desk.perform(.send(session: session, text: text)))
        case .task(let session, let summary, let body):
            return result(
                await desk.perform(.create(destination: session, summary: summary, body: body, priority: .routine)))
        }
    }

    /// The stop the phone showed, re-read now: same command and same time, as `PromptInstance.check(against:)` decides
    /// on the Mac. The same command asked again is a new prompt. Anything else refuses.
    private static func same(_ session: String, _ command: String, _ observedAt: String, _ desk: some RelayDesk) async
        -> Result<RelayPromptReading, Refusal>
    {
        guard let reading = await desk.prompt(session: session) else {
            return .failure(Refusal(error(409, "prompt_gone", "Nothing is waiting on this seat any more.")))
        }
        guard reading.command == command, reading.observedAt == observedAt else {
            return .failure(Refusal(error(409, "prompt_changed", "Another prompt is up now. Nothing was sent.")))
        }
        return .success(reading)
    }

    /// A row the Mac's Needs you lists for its person; any other row is refused, whatever its id.
    private static func forPerson(_ id: String, _ desk: some RelayDesk) async -> Result<QItem, Refusal> {
        guard let row = await desk.row(id) else { return .failure(Refusal(error(404, "no_such_row", "No row \(id)."))) }
        guard await desk.isForPerson(row) else {
            return .failure(Refusal(error(403, "not_for_you", "This row isn't waiting on you.")))
        }
        return .success(row)
    }

    private static func resolveHeld(_ session: String, _ decision: String, _ desk: some RelayDesk) async {
        guard let row = await desk.heldRow(session: session) else { return }
        _ = await desk.perform(.resolve(id: row, decision: decision))
    }

    private static func result(_ outcome: RelayOutcome) -> RelayResponse {
        outcome == .done ? ok() : failure(outcome)
    }

    private static func failure(_ outcome: RelayOutcome) -> RelayResponse {
        guard case .failed(let message) = outcome else { return ok() }
        // `rig send` refuses a seat stopped at a prompt; the phone says so instead of a generic failure.
        if message.contains("target_needs_input") {
            return error(409, "target_needs_input", "The seat is waiting at a permission prompt.")
        }
        return error(502, "failed", message)
    }

    private static func ok() -> RelayResponse { json(["ok": true]) }

    private static func json(_ value: some Encodable) -> RelayResponse {
        RelayResponse(
            status: 200, headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> RelayResponse {
        RelayResponse(
            status: status, headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(["error": code, "message": message])) ?? Data())
    }

    /// The error code in a refusal's body, e.g. "prompt_changed".
    public static func errorCode(_ response: RelayResponse) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: response.body))?["error"]
    }
}

/// A refusal carried through `Result`.
private struct Refusal: Error {
    let response: RelayResponse
    init(_ response: RelayResponse) { self.response = response }
}

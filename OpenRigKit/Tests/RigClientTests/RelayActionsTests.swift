import Foundation
import RigModel
import Testing

@testable import RigClient

/// The Mac-side calls the phone may make through the relay. Every test runs against a fake desk that records the
/// `RigAction`s it is asked to run: nothing reaches a daemon or a seat.
@Suite struct RelayActionsTests {
    static let seat = "dev-b1@openrig-app"

    static func post(_ path: String, _ body: [String: Any] = [:]) -> RelayRequest {
        RelayRequest(method: "POST", path: path, body: try! JSONSerialization.data(withJSONObject: body))
    }

    @Test func onlyTheListedCallsParse() {
        #expect(RelayCall(RelayRequest(method: "GET", path: "/relay/v1/needs-you")) == .needsYou)
        #expect(
            RelayCall(RelayRequest(method: "GET", path: "/relay/v1/prompts/\(Self.seat)"))
                == .prompt(session: Self.seat))
        #expect(
            RelayCall(Self.post("/relay/v1/prompts/\(Self.seat)/allow-once", ["command": "npm test"]))
                == .allowOnce(session: Self.seat, command: "npm test"))
        #expect(
            RelayCall(Self.post("/relay/v1/prompts/\(Self.seat)/decline", ["command": "rm -rf x", "reason": "no"]))
                == .decline(session: Self.seat, command: "rm -rf x", reason: "no"))
        #expect(
            RelayCall(Self.post("/relay/v1/rows/qitem-1/reply", ["text": "ok"])) == .reply(row: "qitem-1", text: "ok"))
        #expect(RelayCall(Self.post("/relay/v1/rows/qitem-1/got-it")) == .gotIt(row: "qitem-1"))
        #expect(
            RelayCall(Self.post("/relay/v1/rows/qitem-1/done", ["replied": true]))
                == .done(row: "qitem-1", replied: true))
        #expect(
            RelayCall(Self.post("/relay/v1/seats/\(Self.seat)/message", ["text": "hi"]))
                == .message(session: Self.seat, text: "hi"))
        #expect(
            RelayCall(Self.post("/relay/v1/seats/\(Self.seat)/task", ["summary": "S", "body": "B"]))
                == .task(session: Self.seat, summary: "S", body: "B"))
        #expect(RelayCall(RelayRequest(method: "GET", path: "/relay/v1/rigs")) == .rigs)
        #expect(
            RelayCall(RelayRequest(method: "GET", path: "/relay/v1/rigs/openrig-app/seats"))
                == .seats(rig: "openrig-app"))

        let refused = [
            RelayRequest(method: "POST", path: "/relay/v1/needs-you"),
            RelayRequest(method: "GET", path: "/relay/v1/prompts/\(Self.seat)/allow-once"),
            Self.post("/relay/v1/prompts/\(Self.seat)/always-allow", ["command": "x"]),
            Self.post("/relay/v1/prompts/\(Self.seat)/allow-once"),
            Self.post("/relay/v1/seats/\(Self.seat)/message", ["text": "  "]),
            Self.post("/relay/v1/seats/\(Self.seat)/task", ["summary": ""]),
            Self.post("/relay/v1/seats/../message", ["text": "x"]),
            Self.post("/relay/v1/rigs/openrig-app/down"),
            RelayRequest(method: "GET", path: "/relay/v1/rigs/a%2F..%2Fb/seats"),
        ]
        for request in refused { #expect(RelayCall(request) == nil, "\(request.method) \(request.path)") }
    }

    @Test func allowOnceAnswersTheSeatsOwnYes() async {
        let desk = FakeDesk(
            prompt: RelayPromptReading(
                session: Self.seat, seatName: "dev-b1", command: "npm test", allowOnceKey: "1", declineKey: "3"))
        let response = await RelayActions.handle(.allowOnce(session: Self.seat, command: "npm test"), desk: desk)
        #expect(response.status == 200)
        #expect(
            desk.done == [.answerPrompt(session: Self.seat, keys: "1", reason: "OpenRig phone: allow once npm test")])
    }

    /// The phone answers the prompt it showed. If another is up, or none, nothing is typed.
    @Test func anAnswerToAChangedPromptIsRefused() async {
        let changed = FakeDesk(
            prompt: RelayPromptReading(
                session: Self.seat, seatName: "dev-b1", command: "rm -rf build", allowOnceKey: "1", declineKey: "3"))
        let refused = await RelayActions.handle(.allowOnce(session: Self.seat, command: "npm test"), desk: changed)
        #expect(refused.status == 409)
        #expect(RelayActions.errorCode(refused) == "prompt_changed")
        #expect(changed.done.isEmpty)

        let gone = FakeDesk(prompt: nil)
        let none = await RelayActions.handle(.decline(session: Self.seat, command: "npm test", reason: ""), desk: gone)
        #expect(RelayActions.errorCode(none) == "prompt_gone")
        #expect(gone.done.isEmpty)
    }

    /// No plain Yes on screen: the Mac can't tell which key allows once, so it doesn't guess.
    @Test func noReadableYesIsRefused() async {
        let desk = FakeDesk(
            prompt: RelayPromptReading(
                session: Self.seat, seatName: "dev-b1", command: "npm test", allowOnceKey: nil, declineKey: "3"))
        let response = await RelayActions.handle(.allowOnce(session: Self.seat, command: "npm test"), desk: desk)
        #expect(RelayActions.errorCode(response) == "cannot_allow_once")
        #expect(desk.done.isEmpty)
    }

    /// Decline with a reason: the menu's No, then, once the pane is clear, the reason as a message, as the Mac does.
    @Test func declineWithAReasonSendsItAfterward() async {
        let desk = FakeDesk(
            prompt: RelayPromptReading(
                session: Self.seat, seatName: "dev-b1", command: "rm -rf x", allowOnceKey: "1", declineKey: "3"))
        desk.daemonStillHolds = true
        let response = await RelayActions.handle(
            .decline(session: Self.seat, command: "rm -rf x", reason: "use trash"), desk: desk)
        #expect(response.status == 200)
        #expect(
            desk.done == [
                .answerPrompt(session: Self.seat, keys: "3", reason: "OpenRig phone: decline rm -rf x"),
                .clearAttention(session: Self.seat, reason: "OpenRig phone: prompt declined; the pane shows no prompt"),
                .send(session: Self.seat, text: "use trash"),
            ])
    }

    @Test func rowAnswersMatchTheForYouPanel() async throws {
        let row = try JSONDecoder().decode(
            QItem.self,
            from: Data(
                #"{"qitemId":"qitem-1","sourceSession":"orch-lead@openrig-app","destinationSession":"you@external","state":"pending","summary":"FYI"}"#
                    .utf8))
        let desk = FakeDesk(prompt: nil, row: row)
        _ = await RelayActions.handle(.reply(row: "qitem-1", text: "on it"), desk: desk)
        _ = await RelayActions.handle(.gotIt(row: "qitem-1"), desk: desk)
        _ = await RelayActions.handle(.done(row: "qitem-1", replied: true), desk: desk)
        #expect(
            desk.done == [
                .send(session: "orch-lead@openrig-app", text: "on it"),
                Answer(.acknowledge).close(row, told: false),
                Answer(.answered, replied: true).close(row, told: false),
            ])
        let missing = await RelayActions.handle(.gotIt(row: "qitem-none"), desk: FakeDesk(prompt: nil))
        #expect(missing.status == 404)
    }

    /// `rig send` refuses a seat stopped at a prompt; the phone shows that, not a generic failure.
    @Test func aMessageToASeatAtAPromptSaysSo() async {
        let desk = FakeDesk(prompt: nil)
        desk.result = .failed("target_needs_input: the seat is waiting at a permission prompt")
        let response = await RelayActions.handle(.message(session: Self.seat, text: "hi"), desk: desk)
        #expect(response.status == 409)
        #expect(RelayActions.errorCode(response) == "target_needs_input")
        #expect(desk.done == [.send(session: Self.seat, text: "hi")])

        let task = FakeDesk(prompt: nil)
        _ = await RelayActions.handle(.task(session: Self.seat, summary: "S", body: "B"), desk: task)
        #expect(task.done == [.create(destination: Self.seat, summary: "S", body: "B", priority: .routine)])
    }
}

/// Answers from fixed values and records every action instead of running it.
final class FakeDesk: RelayDesk, @unchecked Sendable {
    let reading: RelayPromptReading?
    let row: QItem?
    var daemonStillHolds = false
    var result = RelayOutcome.done
    private(set) var done: [RigAction] = []

    init(prompt: RelayPromptReading?, row: QItem? = nil) {
        self.reading = prompt
        self.row = row
    }

    func needsYou() async -> [RelayNeedsYouItem] { [] }
    func prompt(session: String) async -> RelayPromptReading? { reading }
    func waitForNoPrompt(session: String) async -> (paneClear: Bool, daemonHolds: Bool) { (true, daemonStillHolds) }
    func heldRow(session: String) async -> String? { nil }
    func row(_ id: String) async -> QItem? { row?.id == id ? row : nil }
    func rigs() async -> [RelayRig] { [] }
    func seats(rig: String) async -> [RelaySeat]? { nil }
    func perform(_ action: RigAction) async -> RelayOutcome {
        done.append(action)
        return result
    }
}

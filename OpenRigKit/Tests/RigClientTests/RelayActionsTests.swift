import Foundation
import RigDomain
import RigModel
import Testing

@testable import RigClient

/// The Mac-side calls the phone may make through the relay. Every test runs against a fake desk that records the
/// `RigAction`s it is asked to run: nothing reaches a daemon or a seat.
@Suite struct RelayActionsTests {
    static let seat = "dev-b1@openrig-app"
    static let asked = "2026-11-24T04:00:00.000Z"

    static func post(_ path: String, _ body: [String: Any] = [:]) -> RelayRequest {
        RelayRequest(method: "POST", path: path, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static func reading(_ command: String, asked: String = asked, yes: String? = "1") -> RelayPromptReading {
        RelayPromptReading(
            session: seat, seatName: "dev-b1", command: command, observedAt: asked, allowOnceKey: yes,
            declineKey: "3")
    }

    static func row(to destination: String, state: String = "pending") -> QItem {
        try! JSONDecoder().decode(
            QItem.self,
            from: Data(
                #"{"qitemId":"qitem-1","sourceSession":"orch-lead@openrig-app","destinationSession":"\#(destination)","state":"\#(state)","summary":"FYI"}"#
                    .utf8))
    }

    @Test func onlyTheListedCallsParse() {
        #expect(RelayCall(RelayRequest(method: "GET", path: "/relay/v1/needs-you")) == .needsYou)
        #expect(
            RelayCall(RelayRequest(method: "GET", path: "/relay/v1/prompts/\(Self.seat)"))
                == .prompt(session: Self.seat))
        #expect(
            RelayCall(
                Self.post(
                    "/relay/v1/prompts/\(Self.seat)/allow-once", ["command": "npm test", "observedAt": Self.asked]))
                == .allowOnce(session: Self.seat, command: "npm test", observedAt: Self.asked))
        #expect(
            RelayCall(
                Self.post(
                    "/relay/v1/prompts/\(Self.seat)/decline",
                    ["command": "rm -rf x", "observedAt": "", "reason": "no"]))
                == .decline(session: Self.seat, command: "rm -rf x", observedAt: "", reason: "no"))
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
            Self.post("/relay/v1/prompts/\(Self.seat)/always-allow", ["command": "x", "observedAt": Self.asked]),
            Self.post("/relay/v1/prompts/\(Self.seat)/allow-once", ["observedAt": Self.asked]),
            // Without the stop's time, the Mac can't tell this prompt from the same command asked again.
            Self.post("/relay/v1/prompts/\(Self.seat)/allow-once", ["command": "npm test"]),
            Self.post("/relay/v1/seats/\(Self.seat)/message", ["text": "  "]),
            Self.post("/relay/v1/seats/\(Self.seat)/task", ["summary": ""]),
            Self.post("/relay/v1/seats/../message", ["text": "x"]),
            Self.post("/relay/v1/rigs/openrig-app/down"),
            RelayRequest(method: "GET", path: "/relay/v1/rigs/a%2F..%2Fb/seats"),
        ]
        for request in refused { #expect(RelayCall(request) == nil, "\(request.method) \(request.path)") }
    }

    @Test func allowOnceAnswersTheSeatsOwnYes() async {
        let desk = FakeDesk(prompt: Self.reading("npm test"))
        let response = await RelayActions.handle(
            .allowOnce(session: Self.seat, command: "npm test", observedAt: Self.asked), desk: desk)
        #expect(response.status == 200)
        #expect(
            desk.done == [.answerPrompt(session: Self.seat, keys: "1", reason: "OpenRig phone: allow once npm test")])
    }

    /// The phone answers the stop it showed: another command, the same command asked again, or none, types nothing.
    @Test func anAnswerToAChangedPromptIsRefused() async {
        let changed = FakeDesk(prompt: Self.reading("rm -rf build"))
        let other = await RelayActions.handle(
            .allowOnce(session: Self.seat, command: "npm test", observedAt: Self.asked), desk: changed)
        #expect(other.status == 409)
        #expect(RelayActions.errorCode(other) == "prompt_changed")
        #expect(changed.done.isEmpty)

        let again = FakeDesk(prompt: Self.reading("npm test", asked: "2026-11-24T04:05:00.000Z"))
        let reasked = await RelayActions.handle(
            .allowOnce(session: Self.seat, command: "npm test", observedAt: Self.asked), desk: again)
        #expect(RelayActions.errorCode(reasked) == "prompt_changed")
        #expect(again.done.isEmpty)

        let gone = FakeDesk(prompt: nil)
        let none = await RelayActions.handle(
            .decline(session: Self.seat, command: "npm test", observedAt: Self.asked, reason: ""), desk: gone)
        #expect(RelayActions.errorCode(none) == "prompt_gone")
        #expect(gone.done.isEmpty)
    }

    /// No plain Yes on screen: the Mac can't tell which key allows once, so it doesn't guess.
    @Test func noReadableYesIsRefused() async {
        let desk = FakeDesk(prompt: Self.reading("npm test", yes: nil))
        let response = await RelayActions.handle(
            .allowOnce(session: Self.seat, command: "npm test", observedAt: Self.asked), desk: desk)
        #expect(RelayActions.errorCode(response) == "cannot_allow_once")
        #expect(desk.done.isEmpty)
    }

    /// Decline with a reason: the menu's No, then, once the pane is clear, the reason as a message, as the Mac does;
    /// then the row held on the person is resolved with the decision.
    @Test func declineWithAReasonSendsItAfterward() async {
        let desk = FakeDesk(prompt: Self.reading("rm -rf x"))
        desk.daemonStillHolds = true
        desk.held = "qitem-held"
        let response = await RelayActions.handle(
            .decline(session: Self.seat, command: "rm -rf x", observedAt: Self.asked, reason: "use trash"), desk: desk)
        #expect(response.status == 200)
        #expect(
            desk.done == [
                .answerPrompt(session: Self.seat, keys: "3", reason: "OpenRig phone: decline rm -rf x"),
                .clearAttention(session: Self.seat, reason: "OpenRig phone: prompt declined; the pane shows no prompt"),
                .send(session: Self.seat, text: "use trash"),
                .resolve(id: "qitem-held", decision: "declined: rm -rf x; redirect: use trash"),
            ])
    }

    @Test func rowAnswersMatchTheForYouPanel() async {
        let row = Self.row(to: "you@external")
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

    /// Only a row waiting on the person, as the Mac's Needs you lists it: not a seat's row, not a closed one.
    @Test func aRowNotForThePersonIsRefused() async {
        for row in [Self.row(to: "dev-b2@openrig-app"), Self.row(to: "you@external", state: "done")] {
            let desk = FakeDesk(prompt: nil, row: row)
            for call in [
                RelayCall.gotIt(row: "qitem-1"), .done(row: "qitem-1", replied: false),
                .reply(row: "qitem-1", text: "x"),
            ] {
                let response = await RelayActions.handle(call, desk: desk)
                #expect(response.status == 403, "\(call)")
                #expect(RelayActions.errorCode(response) == "not_for_you")
            }
            #expect(desk.done.isEmpty)
        }
    }

    /// The Mac acts as its own person. If a phone was paired to answer as someone else, it refuses to act for it.
    @Test func actionsStopWhenThePersonDiffers() async {
        let desk = FakeDesk(prompt: Self.reading("npm test"))
        desk.actorMismatch = "This Mac now acts as sam@external; the phone was paired as you@external."
        let response = await RelayActions.handle(.message(session: Self.seat, text: "hi"), desk: desk)
        #expect(response.status == 403)
        #expect(RelayActions.errorCode(response) == "actor_mismatch")
        #expect(desk.done.isEmpty)
        let read = await RelayActions.handle(.needsYou, desk: desk)
        #expect(read.status == 200, "reading still works")
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

/// Answers from fixed values and records every action instead of running it. Rows for the person use the Mac's
/// own rule, `forYou`, with the person `you@external`.
final class FakeDesk: RelayDesk, @unchecked Sendable {
    let reading: RelayPromptReading?
    let row: QItem?
    var daemonStillHolds = false
    var held: String?
    var actorMismatch: String?
    var result = RelayOutcome.done
    private(set) var done: [RigAction] = []

    init(prompt: RelayPromptReading?, row: QItem? = nil) {
        self.reading = prompt
        self.row = row
    }

    func needsYou() async -> [RelayNeedsYouItem] { [] }
    func prompt(session: String) async -> RelayPromptReading? { reading }
    func waitForNoPrompt(session: String) async -> (paneClear: Bool, daemonHolds: Bool) { (true, daemonStillHolds) }
    func heldRow(session: String) async -> String? { held }
    func row(_ id: String) async -> QItem? { row?.id == id ? row : nil }
    func isForPerson(_ row: QItem) async -> Bool { forYou(row, me: "you@external") != nil }
    func refusesActing() async -> String? { actorMismatch }
    func rigs() async -> [RelayRig] { [] }
    func seats(rig: String) async -> [RelaySeat]? { nil }
    func perform(_ action: RigAction) async -> RelayOutcome {
        done.append(action)
        return result
    }
}

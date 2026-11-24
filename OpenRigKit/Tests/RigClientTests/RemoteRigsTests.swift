import Foundation
import RigModel
import Testing

@testable import RigClient

/// What the phone's Rigs tab and seat screen say, and the desk client it builds from a pairing.
@Suite struct RemoteRigsTests {
    static func seat(
        _ name: String = "dev-b2", state: String = "running", activity: String? = "running", atPrompt: Bool = false,
        active: Int = 0, blocked: Int = 0
    ) -> RelaySeat {
        RelaySeat(
            session: "\(name)@openrig-app", name: name, state: state, currentRow: nil, active: active,
            blocked: blocked, contextUsed: nil, runtime: "claude-code", atPrompt: atPrompt, activity: activity)
    }

    // MARK: A seat's look and words

    @Test func eachStateHasItsWords() {
        #expect(Self.seat(activity: "running").look == .working)
        #expect(Self.seat(activity: "running").statusWords == "working")
        #expect(Self.seat(activity: "idle").look == .idle)
        #expect(Self.seat(activity: "idle").statusWords == "idle")
        #expect(Self.seat(activity: "needs_input").look == .needsYou)
        #expect(Self.seat(activity: "needs_input").statusWords == "needs input")
        // A prompt outranks what the activity says.
        #expect(Self.seat(activity: "running", atPrompt: true).look == .needsYou)
        #expect(Self.seat(activity: "running", atPrompt: true).statusWords == "stopped at a prompt")
        // Not running outranks everything: the seat can't act.
        #expect(Self.seat(state: "exited", atPrompt: true).look == .down)
        #expect(Self.seat(state: "exited").statusWords == "down · exited")
        // An older Mac sends no activity: the run state is all there is.
        #expect(Self.seat(activity: nil).look == .unknown)
        #expect(Self.seat(activity: nil).statusWords == "running")
    }

    @Test func queueWordsCountWhatIsOpen() {
        #expect(Self.seat().queueWords == "nothing waiting")
        #expect(Self.seat(active: 3).queueWords == "3 open")
        #expect(Self.seat(active: 3, blocked: 1).queueWords == "3 open · 1 blocked")
    }

    /// `rig send` refuses a seat at a prompt (`target_needs_input`) and can't reach one that's down. A task waits in
    /// the queue either way, so it stays on.
    @Test func messageIsOffAtAPromptOrDownAndATaskStaysOn() {
        #expect(Self.seat().messageBlocked == nil)
        #expect(Self.seat(atPrompt: true).messageBlocked == .atPrompt)
        #expect(Self.seat(state: "detached").messageBlocked == .down)
        #expect(Self.seat(atPrompt: true).messageBlockedWords?.contains("Answer the prompt first") == true)
        #expect(Self.seat(state: "detached").messageBlockedWords?.contains("Queue a task") == true)
        // Mid-message: say it changed and that the draft is kept.
        #expect(Self.seat().composerBlockedWords == nil)
        #expect(Self.seat(atPrompt: true).composerBlockedWords?.hasPrefix("dev-b2 stopped at a prompt") == true)
        #expect(Self.seat(atPrompt: true).composerBlockedWords?.contains("kept here") == true)
    }

    @Test func aRigSummarisesItsSeats() {
        let seats = [
            Self.seat("a"), Self.seat("b"), Self.seat("c", activity: "idle"), Self.seat("d", atPrompt: true),
            Self.seat("e", state: "exited"),
        ]
        #expect(RelaySeat.summary(seats) == "5 seats · 2 working · 1 at a prompt · 1 down")
        #expect(RelaySeat.summary([Self.seat(activity: "idle")]) == "1 seat · nothing running")
    }

    /// The count each rig's row shows: its own Needs-you items, or its line from the other rigs' counts.
    @Test func eachRigCountsWhatWaitsInIt() {
        let list = RelayNeedsYou(
            items: [
                RelayNeedsYouItem(kind: "ask", id: "1", rig: "openrig-app", title: "x"),
                RelayNeedsYouItem(kind: "prompt", id: "2", rig: "openrig-app", title: "y"),
            ],
            attentionElsewhere: [RelayNeedsYou.RigCount(rig: "kernel", count: 3)])
        #expect(list.waiting(in: "openrig-app") == 2)
        #expect(list.waiting(in: "kernel") == 3)
        #expect(list.waiting(in: "other") == 0)
    }

    // MARK: Results in plain words

    @Test func resultsSayWhatHappened() {
        let message = RemoteSend.message(to: "dev-b2")
        let task = RemoteSend.task(for: "dev-b2")
        #expect(message.done == "Message sent to dev-b2.")
        #expect(task.done == "Task queued for dev-b2.")
        #expect(message.words(for: .lostReply).contains("may have been sent"))
        #expect(task.words(for: .lostReply).contains("may have been queued"))
        #expect(message.words(for: .unreachable("x")).contains("not sent"))
        #expect(task.words(for: .unreachable("x")).contains("not queued"))
        #expect(message.words(for: .targetNeedsInput).contains("stopped at a prompt"))
        #expect(
            message.words(for: .actorMismatch("This Mac now acts as b@external.")) == "This Mac now acts as b@external."
        )
        #expect(message.words(for: .failed("tmux gone")).contains("tmux gone"))
    }

    // MARK: The client from a pairing

    static func code(reaches: [PairingCode.Reach], secret: Data?) throws -> PairingCode {
        try PairingCode(
            reaches: reaches, actor: "you@external", credentialID: "cred-a", token: "orapp_x",
            pairingSecret: secret.map(RelayLink.encode))
    }

    @Test func noClientWithoutASecretOrAWiFiReach() throws {
        let secret = RelayLink.newSecret()
        let lan = try PairingCode.Reach(kind: .lan, addresses: ["192.168.1.5"], port: 7433)
        let tailnet = try PairingCode.Reach(kind: .tailnet, addresses: ["mac.tail1234.ts.net"], port: 7433)
        #expect(RelayDeskClient.relay(for: try Self.code(reaches: [lan], secret: nil)) == nil)
        #expect(RelayDeskClient.relay(for: try Self.code(reaches: [tailnet], secret: secret)) == nil)
        #expect(RelayDeskClient.relay(for: try Self.code(reaches: [tailnet, lan], secret: secret)) != nil)
    }

    /// The client tries the pairing's Wi-Fi addresses in order, under the credential id and secret, and `host`
    /// replaces each address (the simulator reaches a loopback relay).
    @Test func theClientReachesTheRelayInThePairing() async throws {
        let secret = RelayLink.newSecret()
        let desk = ClientDesk()
        desk.rigList = [RelayRig(id: "r1", name: "openrig-app", state: "running", seats: 7)]
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0, desk: desk) { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let port = Int(try await relay.start())
        defer { relay.stop() }
        let lan = try PairingCode.Reach(kind: .lan, addresses: ["192.168.1.5", "192.168.1.6"], port: port)
        let client = try #require(
            RelayDeskClient.relay(for: try Self.code(reaches: [lan], secret: secret), host: "127.0.0.1"))
        #expect(try await client.rigs() == desk.rigList)
    }

    /// An older Mac's seat list has no `activity`; it still decodes.
    @Test func aSeatWithoutActivityDecodes() throws {
        let json = #"{"session":"a@r","name":"a","state":"running","active":0,"blocked":0,"atPrompt":false}"#
        let seat = try JSONDecoder().decode(RelaySeat.self, from: Data(json.utf8))
        #expect(seat.activity == nil)
    }
}

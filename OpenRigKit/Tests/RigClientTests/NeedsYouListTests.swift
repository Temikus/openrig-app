import Foundation
import RigModel
import Testing

@testable import RigClient

@Suite struct NeedsYouListTests {
    func asks() throws -> [AppRequest] {
        try JSONDecoder().decode(AppNeedsMe.self, from: appFixture("app-needs-me")).requests
    }

    func item(_ kind: String, _ id: String, row: String? = nil, session: String? = nil) -> RelayNeedsYouItem {
        RelayNeedsYouItem(kind: kind, id: id, rig: "openrig-app", title: "Title \(id)", session: session, row: row)
    }

    /// The Mac lists every ask, the ones with options too. Those come from the app contract and are answered there,
    /// so the relay's copy is dropped.
    @Test func asksWithOptionsAreNotListedTwice() throws {
        let contract = try asks()
        let relay = RelayNeedsYou(items: [
            item("ask", "qitem:\(contract[0].id)", row: contract[0].id),
            item("ask", "qitem:qitem-plain", row: "qitem-plain"),
        ])
        let list = NeedsYouList(asks: contract, relay: relay)
        #expect(list.asks.map(\.id) == contract.map(\.id))
        #expect(list.rows.map(\.row) == ["qitem-plain"])
    }

    @Test func eachKindGoesInItsPlace() throws {
        let relay = RelayNeedsYou(
            items: [
                item("prompt", "p1", session: "dev-b1@openrig-app"), item("fyi", "f1", row: "qitem-f"),
                item("held", "h1", row: "qitem-h"), item("seat", "s1", session: "dev-b2@openrig-app"),
                item("something-new", "n1"),
            ],
            attentionElsewhere: [.init(rig: "kernel", count: 2)])
        let list = NeedsYouList(asks: [], relay: relay)
        #expect(list.prompts.map(\.id) == ["p1"])
        #expect(list.rows.map(\.id) == ["f1", "h1"])
        #expect(list.seatsDown.map(\.id) == ["s1"])
        #expect(list.elsewhere == [.init(rig: "kernel", count: 2)])
    }

    /// Other rigs' prompts and seats down count, so a phone with nothing listed never reads as "nothing is waiting".
    @Test func theCountIncludesOtherRigs() throws {
        let relay = RelayNeedsYou(
            items: [item("fyi", "f1", row: "qitem-f")], attentionElsewhere: [.init(rig: "kernel", count: 2)])
        let list = NeedsYouList(asks: try asks(), relay: relay)
        #expect(list.count == 2 + 1 + 2)
        #expect(!list.isEmpty)
        #expect(
            !NeedsYouList(asks: [], relay: RelayNeedsYou(attentionElsewhere: [.init(rig: "kernel", count: 1)])).isEmpty)
        #expect(NeedsYouList(asks: [], relay: nil).isEmpty)
    }

    @Test func actionsFollowTheMacsForYouPanel() {
        #expect(NeedsYouList.actions(for: item("fyi", "f")) == [.reply, .gotIt])
        #expect(NeedsYouList.actions(for: item("ask", "a")) == [.reply, .done])
        #expect(NeedsYouList.actions(for: item("held", "h")) == [.reply, .done])
        #expect(NeedsYouList.actions(for: item("seat", "s")).isEmpty)
    }
}

/// The session reads the relay's list beside the contract's, through a real relay on 127.0.0.1.
@MainActor @Suite(.serialized, .relaySockets) struct RelayNeedsYouSessionTests {
    @Test func aRelayPairingListsTheMacsPromptsAndOtherRigs() async throws {
        let secret = RelayLink.newSecret()
        let credential = "cred-\(UUID().uuidString)"
        let desk = ClientDesk()
        desk.list = RelayNeedsYou(
            items: [
                RelayNeedsYouItem(
                    kind: "prompt", id: "prompt:dev-b1", rig: "openrig-app", title: "dev-b1 asks to run",
                    detail: "npm test", session: "dev-b1@openrig-app"),
                RelayNeedsYouItem(
                    kind: "fyi", id: "qitem:qitem-f", rig: "openrig-app", title: "Merged", row: "qitem-f"),
            ],
            attentionElsewhere: [.init(rig: "kernel", count: 2)])
        let script = Script([
            .status(200, try appFixture("app-capabilities")), .status(200, try appFixture("app-needs-me-empty")),
        ])
        let server = RelayServer(
            keys: [credential: secret], host: "127.0.0.1", port: 0, desk: desk,
            forward: RelayServer.daemonForwarder(script.baseURL, session: script.session))
        let port = try await server.start()
        defer { server.stop() }

        let link =
            "openrig-remote://pair?v=1&reach=lan:\(port):10.0.0.208&actor=human-example@external&credential=\(credential)"
            + "&token=orapp_t1&secret=\(RelayLink.encode(secret))"
        // The connector and the desk reach 10.0.0.208 through the relay on 127.0.0.1.
        let toLoopback: @Sendable (RemoteEndpoint) -> RemoteEndpoint = { endpoint in
            var endpoint = endpoint
            endpoint.host = "127.0.0.1"
            return endpoint
        }
        let standard = RemoteConnector.standardClient()
        let remote = RemoteSession(
            store: MemoryPairingStore(), outbox: MemoryAnswerOutbox(),
            connector: RemoteConnector(
                client: { standard(toLoopback($0), $1) }, localNetworkDenied: { _ in false }),
            desk: { RelayTransport.deskClient(toLoopback($0), $1) })
        remote.pair(link: link)
        await remote.refresh()

        let list = try #require(remote.needsYouList)
        #expect(list.prompts.map(\.session) == ["dev-b1@openrig-app"])
        #expect(list.rows.map(\.row) == ["qitem-f"])
        #expect(list.elsewhere == [.init(rig: "kernel", count: 2)])
        #expect(remote.desk != nil)
    }
}

@Suite struct PromptOutcomeTests {
    @Test(arguments: [
        (PromptOutcome.Action.allowOnce, Result<Void, RelayDeskError>.success(()), PromptOutcome.allowed),
        (.decline(reason: ""), .success(()), .declined(withNote: false)),
        (.decline(reason: "use the other build"), .success(()), .declined(withNote: true)),
        (.allowOnce, .failure(.probablyAnswered), .probablyAnswered),
        (.allowOnce, .failure(.answeredThenNewPrompt), .answeredThenNewPrompt),
        (.allowOnce, .failure(.promptChanged), .changed),
        (.decline(reason: ""), .failure(.promptGone), .gone),
        (.allowOnce, .failure(.cannotAllowOnce), .cannotAllowOnce),
        (.decline(reason: ""), .failure(.cannotDecline), .cannotDecline),
        (.allowOnce, .failure(.lostReply), .lostReply),
        (.allowOnce, .failure(.unreachable("down")), .unreachable),
        (.allowOnce, .failure(.notForYou), .gone),
        (.allowOnce, .failure(.actorMismatch("other@external")), .failed("other@external")),
    ])
    func eachResultHasItsOutcome(
        action: PromptOutcome.Action, result: Result<Void, RelayDeskError>, outcome: PromptOutcome
    ) {
        #expect(PromptOutcome(action, result) == outcome)
    }

    /// Only an answer that never left the phone can be tried again; anything that may have gone through can't.
    @Test func onlyAnUnsentAnswerKeepsItsButtons() {
        #expect(PromptOutcome.unreachable.keepsButtons)
        for sent in [PromptOutcome.allowed, .lostReply, .probablyAnswered, .gone, .changed] {
            #expect(!sent.keepsButtons)
        }
        #expect(PromptOutcome.changed.offersNewPrompt)
        #expect(PromptOutcome.answeredThenNewPrompt.offersNewPrompt)
        #expect(!PromptOutcome.gone.offersNewPrompt)
    }

    @Test func aReReadSaysWhetherThePromptChanged() {
        let shown = RelayPrompt(
            session: "s", seat: "dev-b1", command: "npm test", observedAt: "t1", canAllowOnce: true, canDecline: true)
        var asked = shown
        #expect(PromptCheck(shown: shown, now: .success(asked)) == .same)
        asked.observedAt = "t2"
        #expect(PromptCheck(shown: shown, now: .success(asked)) == .changed(asked))
        #expect(PromptCheck(shown: shown, now: .failure(.promptGone)) == .gone)
        #expect(PromptCheck(shown: shown, now: .failure(.unreachable("x"))) == .unknown)
    }
}

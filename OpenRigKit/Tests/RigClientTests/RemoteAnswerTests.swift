import Foundation
import RigModel
import Synchronization
import Testing

@testable import RigClient

/// Answering from the phone, against a scripted daemon. Nothing here reaches a real one.
@MainActor @Suite struct RemoteAnswerTests {
    let link =
        "openrig-remote://pair?v=1&reach=loopback:7433:127.0.0.1&actor=human-example@external&credential=c&token=orapp_t1"

    /// The needs-me fixture with its first ask fresh: nothing answered, read at revision "dr1-read".
    func needsMe() throws -> Data {
        var json = try JSONSerialization.jsonObject(with: appFixture("app-needs-me")) as! [String: Any]
        var requests = json["requests"] as! [[String: Any]]
        requests[0]["humanAnswers"] = [String: Any]()
        requests[0]["decisionRevision"] = "dr1-read"
        json["requests"] = requests
        return try JSONSerialization.data(withJSONObject: json)
    }

    func emptyNeedsMe() throws -> Data { try appFixture("app-needs-me-empty") }

    /// A paired session whose Mac is `script`, with the list already read once.
    func session(
        _ replies: [ScriptedProtocol.Reply], outbox: any AnswerOutbox = MemoryAnswerOutbox()
    ) async throws -> (RemoteSession, Script) {
        let script = Script(try [.status(200, needsMe())] + replies)
        let endpoint = RemoteEndpoint(kind: .loopback, host: "127.0.0.1", port: 7433)
        let client = script.client()
        let remote = RemoteSession(
            store: MemoryPairingStore(), outbox: outbox, answerRetryDelay: .zero,
            connect: { _ in RemoteConnector.Outcome(status: .connected(endpoint), client: client) })
        remote.pair(link: link)
        await remote.refresh()
        return (remote, script)
    }

    func posts(_ script: Script) -> [ScriptedProtocol.Seen] { script.requests.filter { $0.method == "POST" } }

    func bodies(_ script: Script) throws -> [[String: Any]] {
        try posts(script).map { try JSONSerialization.jsonObject(with: $0.body ?? Data()) as! [String: Any] }
    }

    @Test func sendsEachOpenQuestionInOrderAtTheRevisionTheLastReceiptGave() async throws {
        let (remote, script) = try await session([
            .status(200, try appFixture("app-receipt-recorded")), .status(200, try appFixture("app-receipt-returned")),
            .status(200, try emptyNeedsMe()),
        ])
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(picks: ["notify": "push", "reach": "wifi"]), for: ask)
        await remote.send(ask)

        let sent = try bodies(script)
        #expect(sent.map { $0["questionId"] as? String } == ["reach", "notify"])
        // The second goes at the revision the first receipt returned, not the one first read.
        #expect(sent.map { $0["expectedRevision"] as? String } == ["dr1-read", "dr1-0a1b2c3d4e5f60718293a4b5"])
        let record = try #require(remote.sent[ask.id])
        #expect(record.outcome == .returned)
        #expect(record.answers.map(\.answer) == ["Option B", "Option B"])
        #expect(remote.draft(for: ask) == AppAnswerDraft())
        #expect(remote.shownRequests?.isEmpty == true)
    }

    @Test func aReplyIsOneSubmissionUnderTheFirstOpenQuestion() async throws {
        let (remote, script) = try await session([
            .status(200, try appFixture("app-receipt-returned")), .status(200, try emptyNeedsMe()),
        ])
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(reply: "Wi-Fi for now."), for: ask)
        await remote.send(ask)

        let sent = try bodies(script)
        #expect(sent.count == 1)
        #expect(sent.first?["questionId"] as? String == "reach")
        #expect((sent.first?["answer"] as? [String: String])?["text"] == "Wi-Fi for now.")
        #expect(remote.sent[ask.id]?.answers.map(\.answer) == ["Wi-Fi for now."])
    }

    @Test func aKeptAnswerSaysSo() async throws {
        let (remote, _) = try await session([
            .status(200, try appFixture("app-receipt-recorded")), .status(200, try appFixture("app-receipt-kept")),
            .status(200, try emptyNeedsMe()),
        ])
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(picks: ["reach": "wifi", "notify": "push"]), for: ask)
        await remote.send(ask)
        #expect(remote.sent[ask.id]?.outcome == .kept(message: "Message text."))
    }

    @Test func someoneAnsweringFirstIsAlreadyAnswered() async throws {
        let outbox = MemoryAnswerOutbox()
        let (remote, _) = try await session(
            [.status(409, try appFixture("app-error-409-returned")), .status(200, try emptyNeedsMe())], outbox: outbox)
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(reply: "Fine."), for: ask)
        await remote.send(ask)
        #expect(remote.sent[ask.id]?.outcome == .alreadyAnswered)
        #expect(try outbox.load().isEmpty)
    }

    @Test func anAskThatChangedNeedsALookAgain() async throws {
        let conflict = Data(#"{"error":"decision_revision_changed","currentRevision":"dr1-new"}"#.utf8)
        let (remote, _) = try await session([.status(409, conflict), .status(200, try emptyNeedsMe())])
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(reply: "Fine."), for: ask)
        await remote.send(ask)
        #expect(remote.sent[ask.id]?.outcome == .changed)
        // The picks wait for the fresh look.
        #expect(remote.draft(for: ask).reply == "Fine.")
        remote.forgetSent(ask.id)
        #expect(remote.sent[ask.id] == nil)
    }

    /// The contract: save the id and body before sending, and after an uncertain end resend exactly those. Three
    /// attempts answer 503, then the check after Send resends once more, and that answers 503 too.
    @Test func anUnfinishedSendStaysQueuedUnderItsID() async throws {
        let outbox = MemoryAnswerOutbox()
        let unsaved = try appFixture("app-error-503-unsaved")
        let (remote, script) = try await session(
            [
                .status(503, unsaved), .status(503, unsaved), .status(503, unsaved), .status(200, try needsMe()),
                .status(503, unsaved),
            ], outbox: outbox)
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(reply: "Fine."), for: ask)
        await remote.send(ask)

        #expect(remote.sent[ask.id]?.outcome == .notFinished)
        let pending = try outbox.load()
        #expect(pending.count == 1)
        let paths = posts(script).map(\.path)
        #expect(paths.count == 4)
        #expect(Set(paths) == ["/api/apps/v1/answers/\(pending[0].id)"])
    }

    @Test func aResendThatFinishesUpdatesTheRecord() async throws {
        let outbox = MemoryAnswerOutbox()
        let unsaved = try appFixture("app-error-503-unsaved")
        let (remote, script) = try await session(
            [
                .status(503, unsaved), .status(503, unsaved), .status(503, unsaved), .status(200, try needsMe()),
                .status(200, try appFixture("app-receipt-returned")),
            ], outbox: outbox)
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(reply: "Fine."), for: ask)
        await remote.send(ask)

        #expect(remote.sent[ask.id]?.outcome == .returned)
        #expect(try outbox.load().isEmpty)
        #expect(Set(posts(script).map(\.path)).count == 1)
    }

    @Test func nothingIsSentBeforeEveryQuestionIsPicked() async throws {
        let (remote, script) = try await session([])
        let ask = try #require(remote.shownRequests?.first)
        remote.setDraft(AppAnswerDraft(picks: ["reach": "wifi"]), for: ask)
        await remote.send(ask)
        #expect(posts(script).isEmpty)
        #expect(remote.sent[ask.id] == nil)
    }

    @Test func picksAreKeptPerAskUntilSent() async throws {
        let (remote, _) = try await session([])
        let asks = try #require(remote.shownRequests)
        remote.setDraft(AppAnswerDraft(picks: ["reach": "wifi"]), for: asks[0])
        remote.setDraft(AppAnswerDraft(reply: "Later."), for: asks[1])
        #expect(remote.draft(for: asks[0]).picks == ["reach": "wifi"])
        #expect(remote.draft(for: asks[1]).reply == "Later.")
    }

    @Test func keepFreshChecksAgainWhileItRuns() async throws {
        let checks = Mutex(0)
        let remote = RemoteSession(
            store: MemoryPairingStore(),
            connect: { _ in
                checks.withLock { $0 += 1 }
                return RemoteConnector.Outcome(status: .unreachable(detail: nil), client: nil)
            })
        remote.pair(link: link)
        let running = Task { await remote.keepFresh(every: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        running.cancel()
        await running.value
        #expect(checks.withLock { $0 } >= 3)
    }
}

@Suite struct AnswerOutboxTests {
    let binding = AppAnswerBinding(
        actor: "human-example@external", requestId: "qitem-1", questionId: "q", episodeKey: nil,
        expectedRevision: "dr1", answer: .option("a"))

    @Test func aFileOutboxSurvivesBeingOpenedAgain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileAnswerOutbox(url: url).add(PendingAnswer(id: "answer1234", binding: binding))
        let reopened = FileAnswerOutbox(url: url)
        #expect(try reopened.load() == [PendingAnswer(id: "answer1234", binding: binding)])
        try reopened.remove(id: "answer1234")
        #expect(try FileAnswerOutbox(url: url).load().isEmpty)
    }
}

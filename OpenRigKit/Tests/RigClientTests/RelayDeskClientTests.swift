import Foundation
import Network
import RigDomain
import RigModel
import Testing

@testable import RigClient

/// The phone's client for the relay's Mac-side calls, against a real `RelayServer` on 127.0.0.1 and a test desk. No
/// daemon, no seat.
@Suite(.serialized) struct RelayDeskClientTests {
    static let seat = "dev-b1@openrig-app"
    static let asked = "2026-11-24T04:00:00.000Z"
    let secret = RelayLink.newSecret()

    /// A started relay with `desk`, and its port.
    func serve(_ desk: ClientDesk) async throws -> (RelayServer, UInt16) {
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0, desk: desk) { _ in
            AsyncThrowingStream { $0.finish() }
        }
        return (relay, try await relay.start())
    }

    /// A relay with `desk`, and a client that opens a fresh channel to it whenever it needs one.
    func start(_ desk: ClientDesk) async throws -> (RelayServer, RelayDeskClient) {
        let (relay, port) = try await serve(desk)
        return (relay, client(ports: [port]))
    }

    /// A client whose first channel goes to the first port and every later one to the last.
    func client(ports: [UInt16], keep: ChannelBox? = nil) -> RelayDeskClient {
        let opened = Counter()
        let secret = self.secret
        return RelayDeskClient {
            let port = ports[min(opened.next(), ports.count - 1)]
            let channel = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
            try await channel.open()
            keep?.add(channel)
            return channel
        }
    }

    @Test func readsRoundTrip() async throws {
        let desk = ClientDesk()
        desk.list = RelayNeedsYou(
            items: [RelayNeedsYouItem(kind: "ask", id: "qitem:q1", rig: "openrig-app", title: "Pick one", row: "q1")],
            attentionElsewhere: [.init(rig: "denkeeper", count: 2)])
        desk.rigList = [RelayRig(id: "r1", name: "openrig-app", state: "running", seats: 7)]
        desk.seatList = [
            RelaySeat(
                session: Self.seat, name: "dev-b1", state: "running", currentRow: "task 10", active: 1, blocked: 0,
                contextUsed: 0.4, runtime: "claude-code", atPrompt: true)
        ]
        let (relay, client) = try await start(desk)
        defer { relay.stop() }
        #expect(try await client.needsYou() == desk.list)
        #expect(try await client.rigs() == desk.rigList)
        #expect(try await client.seats(rig: "openrig-app") == desk.seatList)
        let prompt = try await client.prompt(session: Self.seat)
        #expect(prompt.command == "npm test")
        #expect(prompt.observedAt == Self.asked)
        #expect(prompt.canAllowOnce && prompt.canDecline)
    }

    @Test func actingCallsRoundTrip() async throws {
        let desk = ClientDesk()
        desk.rowForYou = true
        let (relay, client) = try await start(desk)
        defer { relay.stop() }
        let prompt = try await client.prompt(session: Self.seat)
        try await client.allowOnce(prompt)
        desk.reading = ClientDesk.prompt()
        try await client.decline(try await client.prompt(session: Self.seat), reason: "")
        try await client.reply(row: "qitem-1", text: "on it")
        try await client.gotIt(row: "qitem-1")
        try await client.done(row: "qitem-1", replied: true)
        try await client.message(session: Self.seat, text: "hi")
        try await client.task(session: Self.seat, summary: "S", body: "B")
        #expect(desk.done.count == 7)
        #expect(
            desk.done.first
                == .answerPrompt(session: Self.seat, keys: "1", reason: "OpenRig phone: allow once npm test"))
        #expect(desk.done.last == .create(destination: Self.seat, summary: "S", body: "B", priority: .routine))
    }

    @Test func eachRefusalDecodes() async throws {
        let desk = ClientDesk()
        let (relay, client) = try await start(desk)
        defer { relay.stop() }
        let shown = try await client.prompt(session: Self.seat)

        await #expect(throws: RelayDeskError.notForYou) { try await client.gotIt(row: "qitem-1") }

        desk.reading = ClientDesk.prompt(asked: "2026-11-24T04:09:00.000Z")
        await #expect(throws: RelayDeskError.promptChanged) { try await client.allowOnce(shown) }

        desk.reading = nil
        await #expect(throws: RelayDeskError.promptGone) { try await client.decline(shown, reason: "") }
        await #expect(throws: RelayDeskError.promptGone) { _ = try await client.prompt(session: Self.seat) }

        desk.reading = ClientDesk.prompt(yes: nil)
        await #expect(throws: RelayDeskError.cannotAllowOnce) { try await client.allowOnce(shown) }
        desk.reading = ClientDesk.prompt(no: nil)
        await #expect(throws: RelayDeskError.cannotDecline) { try await client.decline(shown, reason: "") }

        desk.result = .failed("target_needs_input: waiting at a prompt")
        await #expect(throws: RelayDeskError.targetNeedsInput) {
            try await client.message(session: Self.seat, text: "x")
        }
        desk.result = .failed("rig exited with status 1")
        await #expect(throws: RelayDeskError.failed("rig exited with status 1")) {
            try await client.task(session: Self.seat, summary: "S", body: "")
        }

        desk.result = .done
        desk.mismatch = "This Mac now acts as sam@external."
        await #expect(throws: RelayDeskError.actorMismatch("This Mac now acts as sam@external.")) {
            try await client.message(session: Self.seat, text: "x")
        }
        desk.mismatch = nil

        await #expect(throws: RelayDeskError.notFound("No rig nowhere.")) { _ = try await client.seats(rig: "nowhere") }
        #expect(desk.done.count == 2, "only the two whose action ran and failed")
    }

    /// A relay without a desk refuses every Mac-side call: the phone says the Mac can't do it.
    @Test func aRelayWithoutADeskRefuses() async throws {
        let relay = RelayServer(keys: ["cred-a": secret], host: "127.0.0.1", port: 0) { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let port = try await relay.start()
        defer { relay.stop() }
        let secret = self.secret
        let client = RelayDeskClient {
            let channel = RelayChannel(host: "127.0.0.1", port: port, identity: "cred-a", secret: secret)
            try await channel.open()
            return channel
        }
        await #expect(throws: RelayDeskError.refused) { _ = try await client.needsYou() }
    }

    /// A read lost with its connection is asked again on a new one.
    @Test func aReadRetriesOnANewConnection() async throws {
        let desk = ClientDesk()
        let (first, one) = try await serve(desk)
        let (second, two) = try await serve(desk)
        defer { second.stop() }
        let client = client(ports: [one, two])
        desk.onRead = { first.stop() }
        #expect(try await client.rigs() == [])
        #expect(desk.reads == 2, "asked once on each connection")
    }

    /// Allow once whose reply is lost: the client resends once on a new connection. The first went through, so the
    /// Mac's re-read finds the stop gone and refuses; nothing is typed twice, and the phone hears `probablyAnswered`.
    @Test func allowOnceResentAfterALostReplyTypesOnce() async throws {
        let desk = ClientDesk()
        let (first, one) = try await serve(desk)
        let (second, two) = try await serve(desk)
        defer { second.stop() }
        let client = client(ports: [one, two])
        let shown = try await client.prompt(session: Self.seat)
        desk.onPerform = {
            desk.reading = nil  // the answer took: the prompt is gone
            first.stop()  // and the reply is lost with the connection
        }
        await #expect(throws: RelayDeskError.probablyAnswered) { try await client.allowOnce(shown) }
        #expect(desk.done.count == 1)
    }

    /// The same, but the seat asked again meanwhile: the phone hears its answer went through and a new prompt is up.
    @Test func aResendThatFindsANewPromptSaysSo() async throws {
        let desk = ClientDesk()
        let (first, one) = try await serve(desk)
        let (second, two) = try await serve(desk)
        defer { second.stop() }
        let client = client(ports: [one, two])
        let shown = try await client.prompt(session: Self.seat)
        desk.onPerform = {
            desk.reading = ClientDesk.prompt(asked: "2026-11-24T04:01:00.000Z")
            first.stop()
        }
        await #expect(throws: RelayDeskError.answeredThenNewPrompt) { try await client.decline(shown, reason: "") }
        #expect(desk.done.count == 1)
    }

    /// review-code's probe: the phone polls Needs you while the person taps. Reads and messages at once share one
    /// channel, one call at a time, and every message is performed exactly once.
    @Test func callsAtOnceShareTheChannel() async throws {
        let desk = ClientDesk()
        desk.slowReads = true
        let (relay, client) = try await start(desk)
        defer { relay.stop() }
        _ = try await client.rigs()  // the channel is open before the burst, so every call shares it
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask { _ = try await client.rigs() }
                group.addTask { try await client.message(session: Self.seat, text: "m\(n)") }
            }
            try await group.waitForAll()
        }
        #expect(desk.done.count == 20)
    }

    /// A channel the system has marked failed or cancelled while idle isn't sent on: the call goes out on a new one,
    /// and isn't a lost reply. (A peer that closes cleanly still reads as ready to Network until the next read; that
    /// case stays `lostReply`.)
    @Test func aChannelThatDiedIdleIsReplaced() async throws {
        let desk = ClientDesk()
        let (relay, port) = try await serve(desk)
        defer { relay.stop() }
        let channels = ChannelBox()
        let client = client(ports: [port], keep: channels)
        _ = try await client.rigs()
        channels.first?.close()
        try await Task.sleep(for: .milliseconds(100))
        try await client.message(session: Self.seat, text: "after idle")
        #expect(desk.done == [.send(session: Self.seat, text: "after idle")])
        #expect(channels.count == 2, "a new channel was opened")
    }

    /// Any other acting call isn't resent: a lost reply may mean it ran, so the phone is told, not the seat twice.
    @Test func aMessageWithALostReplyIsNotResent() async throws {
        let desk = ClientDesk()
        let (first, one) = try await serve(desk)
        let (second, two) = try await serve(desk)
        defer { second.stop() }
        let client = client(ports: [one, two])
        desk.onPerform = { first.stop() }
        await #expect(throws: RelayDeskError.lostReply) { try await client.message(session: Self.seat, text: "hi") }
        #expect(desk.done.count == 1)
    }
}

/// The channels a test client opened, in order.
final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [RelayChannel] = []
    func add(_ channel: RelayChannel) { lock.withLock { channels.append(channel) } }
    var first: RelayChannel? { lock.withLock { channels.first } }
    var count: Int { lock.withLock { channels.count } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.withLock {
            defer { value += 1 }; return value
        }
    }
}

/// A desk with settable answers that records every action. Reads and actions can run a hook, to drop a connection.
final class ClientDesk: RelayDesk, @unchecked Sendable {
    static func prompt(asked: String = RelayDeskClientTests.asked, yes: String? = "1", no: String? = "3")
        -> RelayPromptReading
    {
        RelayPromptReading(
            session: RelayDeskClientTests.seat, seatName: "dev-b1", command: "npm test", observedAt: asked,
            allowOnceKey: yes, declineKey: no)
    }

    private let lock = NSLock()
    var reading: RelayPromptReading? = ClientDesk.prompt()
    var list = RelayNeedsYou()
    var rigList: [RelayRig] = []
    var seatList: [RelaySeat] = []
    var rowForYou = false
    var mismatch: String?
    var result = RelayOutcome.done
    var onPerform: (@Sendable () -> Void)?
    var onRead: (@Sendable () -> Void)?
    /// Reads take a moment, so a call beside one would cross it if the channel weren't one call at a time.
    var slowReads = false
    private(set) var done: [RigAction] = []
    private(set) var reads = 0

    func needsYou() async -> RelayNeedsYou { list }
    func prompt(session: String) async -> RelayPromptReading? { lock.withLock { reading } }
    func waitForNoPrompt(session: String) async -> (paneClear: Bool, daemonHolds: Bool) { (true, false) }
    func heldRow(session: String) async -> String? { nil }
    func row(_ id: String) async -> QItem? {
        try? JSONDecoder().decode(
            QItem.self,
            from: Data(
                #"{"qitemId":"\#(id)","sourceSession":"orch-lead@openrig-app","destinationSession":"\#(rowForYou ? "you@external" : "dev-b2@openrig-app")","state":"pending","summary":"x"}"#
                    .utf8))
    }
    func isForPerson(_ row: QItem) async -> Bool { forYou(row, me: "you@external") != nil }
    func refusesActing() async -> String? { mismatch }
    func rigs() async -> [RelayRig] {
        let hook = lock.withLock {
            reads += 1
            return reads == 1 ? onRead : nil
        }
        hook?()
        if slowReads { try? await Task.sleep(for: .milliseconds(20)) }
        return rigList
    }
    func seats(rig: String) async -> [RelaySeat]? { rig == "openrig-app" ? seatList : nil }
    func perform(_ action: RigAction) async -> RelayOutcome {
        let hook = lock.withLock {
            done.append(action)
            return done.count == 1 ? onPerform : nil
        }
        hook?()
        return result
    }
}

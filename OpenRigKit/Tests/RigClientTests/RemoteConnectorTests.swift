import Foundation
import RigModel
import Synchronization
import Testing

@testable import RigClient

@Suite struct RemoteConnectorTests {
    typealias Reach = PairingCode.Reach
    let token = "orapp_" + String(repeating: "cd", count: 32)

    func code(_ reaches: [Reach]) throws -> PairingCode {
        try PairingCode(reaches: reaches, actor: "human-example@external", credentialID: "cred-1", token: token)
    }

    /// Each endpoint gets its own scripted host. An endpoint with no script fails like a dead address.
    func connector(
        _ scripts: [String: Script], denied: Bool = false, probed: Probe = Probe()
    ) -> RemoteConnector {
        RemoteConnector(
            client: { endpoint, code in
                let script = scripts[endpoint.description] ?? Script([.drop, .drop, .drop])
                return AppClient(
                    baseURL: script.baseURL, token: code.token, actor: code.actor, session: script.session)
            },
            localNetworkDenied: { endpoint in
                probed.record(endpoint)
                return denied
            })
    }

    var capabilities: Data { get throws { try appFixture("app-capabilities") } }

    @Test func triesReachesAndAddressesInOrderAndStopsAtTheFirstThatAnswers() async throws {
        let first = Script([.drop])
        let second = Script([.drop])
        let third = Script([.status(200, try capabilities)])
        let fourth = Script([.status(200, try capabilities)])
        let pairing = try code([
            Reach(kind: .lan, addresses: ["mac.local", "10.0.0.208"], port: 7433),
            Reach(kind: .loopback, addresses: ["127.0.0.1", "localhost"], port: 7433),
        ])
        let outcome = await connector([
            "mac.local:7433": first, "10.0.0.208:7433": second, "127.0.0.1:7433": third, "localhost:7433": fourth,
        ]).connect(pairing)

        let expected = RemoteEndpoint(kind: .loopback, host: "127.0.0.1", port: 7433)
        #expect(outcome.status == .connected(expected))
        #expect(outcome.client?.baseURL == third.baseURL)
        #expect([first, second, third].map(\.requests.count) == [1, 1, 1])
        #expect(fourth.requests.isEmpty)
        #expect(third.requests.first?.path == "/api/apps/v1/capabilities")
        #expect(third.requests.first?.authorization == "Bearer \(token)")
    }

    @Test func endpointURLIsPlainHTTPToTheAddressAndPort() {
        let endpoint = RemoteEndpoint(kind: .lan, host: "10.0.0.208", port: 52_100)
        #expect(endpoint.baseURL == URL(string: "http://10.0.0.208:52100"))
        #expect(endpoint.description == "10.0.0.208:52100")
    }

    @Test func revokedCredentialIsUnpaired() async throws {
        let mac = Script([.status(401, Data(#"{"error":"unauthorized"}"#.utf8))])
        let outcome = await connector(["127.0.0.1:7433": mac]).connect(
            try code([Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433)]))
        #expect(outcome.status == .unpaired)
        #expect(outcome.client == nil)
    }

    @Test func somethingElseAnsweringIsAnUnsupportedDaemon() async throws {
        let other = Script([.status(404, Data("<html>Not found</html>".utf8))])
        let outcome = await connector(["127.0.0.1:8765": other]).connect(
            try code([Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 8765)]))
        #expect(outcome.status == .unsupportedDaemon)
    }

    @Test func anotherContractVersionIsAnUnsupportedDaemon() async throws {
        let newer = Script([.status(200, Data(#"{"contract":"openrig.core-app","version":2,"jobs":[]}"#.utf8))])
        let outcome = await connector(["127.0.0.1:7433": newer]).connect(
            try code([Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433)]))
        #expect(outcome.status == .unsupportedDaemon)
    }

    /// A stale address may now belong to another device. Keep trying; a later endpoint can still answer.
    @Test func aStrangerOnAnEarlierAddressDoesNotStopTheSearch() async throws {
        let stranger = Script([.status(404)])
        let mac = Script([.status(200, try capabilities)])
        let outcome = await connector(["10.0.0.5:7433": stranger, "mac.local:7433": mac]).connect(
            try code([Reach(kind: .lan, addresses: ["10.0.0.5", "mac.local"], port: 7433)]))
        #expect(outcome.status == .connected(RemoteEndpoint(kind: .lan, host: "mac.local", port: 7433)))
    }

    @Test func nothingAnsweringIsUnreachableWithTheLastError() async throws {
        let outcome = await connector([:]).connect(
            try code([Reach(kind: .lan, addresses: ["10.0.0.5"], port: 7433)]))
        guard case .unreachable(let detail) = outcome.status else {
            Issue.record("expected unreachable, got \(outcome.status)")
            return
        }
        #expect(detail?.isEmpty == false)
    }

    @Test func deniedLocalNetworkIsSaidWhenNoLanAddressAnswers() async throws {
        let probe = Probe()
        let outcome = await connector([:], denied: true, probed: probe).connect(
            try code([Reach(kind: .lan, addresses: ["10.0.0.5", "mac.local"], port: 7433)]))
        #expect(outcome.status == .localNetworkDenied)
        #expect(probe.endpoints == [RemoteEndpoint(kind: .lan, host: "10.0.0.5", port: 7433)])
    }

    /// Loopback and tailnet don't need Local Network access, so they never ask about it.
    @Test func noLanReachMeansNoLocalNetworkCheck() async throws {
        let probe = Probe()
        let outcome = await connector([:], denied: true, probed: probe).connect(
            try code([Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433)]))
        #expect(probe.endpoints.isEmpty)
        if case .unreachable = outcome.status {} else { Issue.record("expected unreachable, got \(outcome.status)") }
    }

    /// The credential was revoked: say so even if another address only failed to answer.
    @Test func unpairedOutranksUnreachable() async throws {
        let mac = Script([.status(401)])
        let outcome = await connector(["127.0.0.1:7433": mac]).connect(
            try code([
                Reach(kind: .lan, addresses: ["10.0.0.5"], port: 7433),
                Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433),
            ]))
        #expect(outcome.status == .unpaired)
    }
}

/// Records which endpoints the Local Network check was asked about.
final class Probe: Sendable {
    private let seen = Mutex<[RemoteEndpoint]>([])
    func record(_ endpoint: RemoteEndpoint) { seen.withLock { $0.append(endpoint) } }
    var endpoints: [RemoteEndpoint] { seen.withLock { $0 } }
}

@Suite struct RemotePairingTests {
    let link =
        "openrig-remote://pair?v=1&reach=loopback:7433:127.0.0.1&actor=human-example@external&credential=c1&token=orapp_secret1"

    @Test func keepsTheCodeAndWhenItWasPaired() throws {
        let code = try PairingCode(parsing: link)
        let pairing = RemotePairing(code: code, pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let stored = try JSONEncoder().encode(pairing)
        let back = try JSONDecoder().decode(RemotePairing.self, from: stored)
        #expect(back == pairing)
        #expect(back.code == code)
    }

    @Test func hidesTheTokenFromPrintAndDump() throws {
        let pairing = RemotePairing(code: try PairingCode(parsing: link), pairedAt: .now)
        var dumped = ""
        dump(pairing, to: &dumped)
        for shown in [String(describing: pairing), String(reflecting: pairing), dumped] {
            #expect(!shown.contains("orapp_secret1"))
        }
    }

    @Test func memoryStoreSavesLoadsAndForgets() throws {
        let store = MemoryPairingStore()
        #expect(try store.load() == nil)
        let pairing = RemotePairing(code: try PairingCode(parsing: link), pairedAt: .now)
        try store.save(pairing)
        #expect(try store.load() == pairing)
        try store.delete()
        #expect(try store.load() == nil)
    }
}

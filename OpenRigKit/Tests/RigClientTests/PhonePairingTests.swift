import Foundation
import RigModel
import Testing

@testable import RigClient

@Suite struct PhonePairingTests {
    let credential = try! JSONDecoder().decode(AppCredential.self, from: appFixture("app-credential"))

    /// Until the relay, only the simulator on this Mac can use a code: it reaches the daemon on loopback.
    @Test func aCodeForThisMacReachesTheDaemonOnLoopback() throws {
        let daemon = URL(string: "http://127.0.0.1:7433")!
        let code = try PairingCode.forThisMac(credential: credential, actor: "human-example@external", daemon: daemon)
        #expect(code.reaches == [try PairingCode.Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433)])
        #expect(code.credentialID == credential.id)
        #expect(code.token == credential.token)
        #expect(code.pairingSecret == nil)
        #expect(try PairingCode(parsing: code.url.absoluteString) == code, "the phone reads what the Mac shows")
    }

    /// With the relay listening, the code adds a `lan` reach to it, carries the phone's secret and names the Mac.
    /// Loopback stays first, for the simulator on this Mac.
    @Test func aCodeWithTheRelayReachesItOnTheWiFi() throws {
        let secret = RelayLink.newSecret()
        let relay = RelayReach(addresses: ["artems-mac.local", "192.168.1.5"], port: 7434, secret: secret)
        let code = try PairingCode.forThisMac(
            credential: credential, actor: "human-example@external", daemon: URL(string: "http://127.0.0.1:7433")!,
            relay: relay, name: "Artem's MacBook Pro")
        #expect(
            code.reaches == [
                try PairingCode.Reach(kind: .loopback, addresses: ["127.0.0.1"], port: 7433),
                try PairingCode.Reach(kind: .lan, addresses: ["artems-mac.local", "192.168.1.5"], port: 7434),
            ])
        #expect(code.name == "Artem's MacBook Pro")
        let read = try PairingCode(parsing: code.url.absoluteString)
        #expect(read == code)
        #expect(read.pairingSecret.flatMap(RelayLink.decode) == secret, "the phone gets the same key")
    }

    /// The secret goes in a URL: base64url without padding, and anything else doesn't decode.
    @Test func aSecretSurvivesTheLink() {
        let secret = RelayLink.newSecret()
        let text = RelayLink.encode(secret)
        #expect(!text.contains("+") && !text.contains("/") && !text.contains("="))
        #expect(RelayLink.decode(text) == secret)
        #expect(RelayLink.decode("not base64!") == nil)
        #expect(RelayLink.decode(RelayLink.encode(Data([1, 2, 3]))) == nil, "a secret is 256 bits")
    }

    @Test func aCodeKeepsTheDaemonsPortAndName() throws {
        let code = try PairingCode.forThisMac(
            credential: credential, actor: "human-example@external", daemon: URL(string: "http://localhost:7500/")!)
        #expect(code.reaches.first?.addresses == ["localhost"])
        #expect(code.reaches.first?.port == 7500)
    }

    /// A daemon on another machine can't be reached from this Mac's simulator; the Phone tab says so.
    @Test func noCodeForADaemonElsewhere() {
        #expect(throws: PairingCodeError.unsupportedHost("100.101.12.7")) {
            try PairingCode.forThisMac(
                credential: credential, actor: "human-example@external",
                daemon: URL(string: "http://100.101.12.7:7433")!)
        }
    }

    static let here = URL(string: "http://127.0.0.1:7433")!
    static let other = URL(string: "http://127.0.0.1:7500")!

    func phone(_ id: String, at daemon: URL = here, paired: Date = .now) -> PairedPhone {
        PairedPhone(id: id, name: "", actor: "a@external", paired: paired, daemon: daemon)
    }

    @Test func pairedPhonesNewestFirstAndUnpairRemovesOne() {
        var phones = PairedPhones()
        let first = phone("cred-1", paired: Date(timeIntervalSince1970: 1))
        let second = phone("cred-2", paired: Date(timeIntervalSince1970: 2))
        phones.add(first)
        phones.add(second)
        #expect(phones.list.map(\.id) == ["cred-2", "cred-1"])
        phones.remove(id: "cred-2")
        #expect(phones.list == [first])
    }

    /// The record outlives a relaunch, with the daemon each credential lives on; the token is never part of it.
    @Test func theRecordSurvivesARoundTripWithoutTheToken() throws {
        var phones = PairedPhones()
        phones.add(phone(credential.id))
        let data = phones.data
        #expect(PairedPhones(data: data) == phones)
        #expect(PairedPhones(data: data).list.first?.daemon == "127.0.0.1:7433")
        #expect(!String(decoding: data, as: UTF8.self).contains(credential.token))
    }

    /// Until the relay sees a phone connect, a row is a code that was shown, not a phone known to be paired.
    @Test func anUnnamedRowIsNamedByItsCode() {
        let paired = Date(timeIntervalSince1970: 1_795_000_000)
        var code = phone("cred-1", paired: paired)
        #expect(code.title == "Code from \(paired.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
        code.name = "Artem's iPhone"
        #expect(code.title == "Artem's iPhone")
    }

    /// A credential lives on one daemon. Revoking it on another "succeeds" (DELETE is idempotent) and leaves it live.
    @Test func theListIsTiedToItsDaemon() {
        var phones = PairedPhones()
        phones.add(phone("cred-here"))
        phones.add(phone("cred-there", at: Self.other))
        #expect(phones.list(for: Self.here).map(\.id) == ["cred-here"])
        #expect(phones.list(for: URL(string: "http://127.0.0.1:7433/")!).map(\.id) == ["cred-here"])
        #expect(
            phones.list(for: URL(string: "http://localhost:7433")!).map(\.id) == ["cred-here"], "one daemon, one key")
        #expect(
            phones.refusesRevoke(phone("cred-there", at: Self.other), at: Self.here) == .otherDaemon("127.0.0.1:7500"))
        #expect(phones.refusesRevoke(phone("cred-here"), at: Self.here) == nil)
        #expect(phones.refusesIssue == nil)
    }

    /// OPENRIG_DEBUG_PHONE's made-up state talks to no daemon: Pair a Phone… would get a live token nothing revokes.
    @Test func aMadeUpStateIssuesAndRevokesNothing() {
        var phones = PairedPhones()
        phones.isMadeUp = true
        phones.add(phone("debug-1"))
        #expect(phones.refusesIssue == .madeUp)
        #expect(phones.refusesRevoke(phone("debug-1"), at: Self.here) == .madeUp)
        #expect(PairedPhones(data: phones.data).isMadeUp == false, "never saved as made up")
    }

    /// The record grows (the relay adds a phone's name). A row written before a field existed still reads, so no
    /// live credential drops out of the only list that revokes it.
    @Test func anOlderRecordStillReads() throws {
        let older = Data(#"[{"id": "cred-1", "actor": "a@external", "paired": 0}]"#.utf8)
        let row = try #require(PairedPhones(data: older).list.first)
        #expect(row.id == "cred-1")
        #expect(row.name == "")
        #expect(row.daemon == "127.0.0.1:7433", "pairing only ever ran against this Mac's own daemon")
        let newer = Data(
            #"[{"id": "cred-2", "actor": "a@external", "paired": 0, "daemon": "127.0.0.1:7500", "x": 1}]"#.utf8)
        #expect(PairedPhones(data: newer).list.first?.daemon == "127.0.0.1:7500")
    }

    /// No code a phone could never use: with the relay off or no Wi-Fi address, Pair says why instead. Held to
    /// loopback (the simulator), a loopback-only code is the point.
    @Test func pairingNeedsAWayInForAPhone() {
        let phones = PairedPhones()
        #expect(phones.refusesPairing(relayOn: true, heldToLoopback: false, wifiAddresses: ["192.168.1.5"]) == nil)
        #expect(
            phones.refusesPairing(relayOn: false, heldToLoopback: false, wifiAddresses: ["192.168.1.5"]) == .relayOff)
        #expect(phones.refusesPairing(relayOn: true, heldToLoopback: false, wifiAddresses: []) == .noWiFiAddress)
        #expect(phones.refusesPairing(relayOn: true, heldToLoopback: true, wifiAddresses: []) == nil)
        #expect(phones.refusesPairing(relayOn: false, heldToLoopback: true, wifiAddresses: []) == .relayOff)
    }

    /// After the credential is issued and the relay restarted, the code must carry a way in, or it isn't shown.
    @Test func aCodeWithoutAWayInIsRefused() {
        let phones = PairedPhones()
        let reach = RelayReach(addresses: ["192.168.1.5"], port: 7434, secret: RelayLink.newSecret())
        #expect(phones.refusesCode(relay: reach, heldToLoopback: false) == nil)
        #expect(phones.refusesCode(relay: nil, heldToLoopback: false) == .noWiFiAddress)
        #expect(phones.refusesCode(relay: nil, heldToLoopback: true) == nil)
    }

    /// Held to loopback, the Mac still shows the code (the simulator needs it), but says only the simulator can use it.
    @Test func aLoopbackOnlyCodeIsForTheSimulator() throws {
        let daemon = URL(string: "http://127.0.0.1:7433")!
        let held = try PairingCode.forThisMac(credential: credential, actor: "human-example@external", daemon: daemon)
        #expect(held.onlyThisMac)
        let relay = RelayReach(addresses: ["192.168.1.5"], port: 7434, secret: RelayLink.newSecret())
        let wifi = try PairingCode.forThisMac(
            credential: credential, actor: "human-example@external", daemon: daemon, relay: relay)
        #expect(!wifi.onlyThisMac)
        #expect(PairedPhones.simulatorOnly.contains("OPENRIG_RELAY_WIFI=1"), "says how to pair a real phone")
    }

    @Test func aDamagedRecordReadsAsEmpty() {
        #expect(PairedPhones(data: Data("not json".utf8)) == PairedPhones())
        #expect(PairedPhones(data: nil) == PairedPhones())
    }
}

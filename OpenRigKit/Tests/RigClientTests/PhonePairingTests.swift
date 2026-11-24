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

    @Test func aDamagedRecordReadsAsEmpty() {
        #expect(PairedPhones(data: Data("not json".utf8)) == PairedPhones())
        #expect(PairedPhones(data: nil) == PairedPhones())
    }
}

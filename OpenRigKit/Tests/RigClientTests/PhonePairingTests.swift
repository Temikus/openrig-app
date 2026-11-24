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

    @Test func pairedPhonesNewestFirstAndUnpairRemovesOne() {
        var phones = PairedPhones()
        let first = PairedPhone(
            id: "cred-1", name: "Phone", actor: "a@external", paired: Date(timeIntervalSince1970: 1))
        let second = PairedPhone(
            id: "cred-2", name: "Phone", actor: "a@external", paired: Date(timeIntervalSince1970: 2))
        phones.add(first)
        phones.add(second)
        #expect(phones.list.map(\.id) == ["cred-2", "cred-1"])
        phones.remove(id: "cred-2")
        #expect(phones.list == [first])
    }

    /// The record outlives a relaunch; the token is never part of it.
    @Test func theRecordSurvivesARoundTripWithoutTheToken() throws {
        var phones = PairedPhones()
        phones.add(PairedPhone(id: credential.id, name: "Phone", actor: "a@external", paired: .now))
        let data = phones.data
        #expect(PairedPhones(data: data) == phones)
        #expect(!String(decoding: data, as: UTF8.self).contains(credential.token))
    }

    @Test func aDamagedRecordReadsAsEmpty() {
        #expect(PairedPhones(data: Data("not json".utf8)) == PairedPhones())
        #expect(PairedPhones(data: nil) == PairedPhones())
    }
}

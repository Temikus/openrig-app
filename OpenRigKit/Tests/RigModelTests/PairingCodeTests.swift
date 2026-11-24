import Foundation
import Testing

@testable import RigModel

@Suite struct PairingCodeTests {
    typealias Reach = PairingCode.Reach
    let token = "orapp_" + String(repeating: "ab", count: 32)
    let lan = "reach=lan:7433:192.168.1.5"
    let rest = "actor=a@b&credential=c&token=orapp_x"

    func code(
        _ reaches: [Reach]? = nil, actor: String = "artem@external", secret: String? = nil
    ) throws -> PairingCode {
        try PairingCode(
            reaches: reaches ?? [Reach(kind: .lan, addresses: ["192.168.1.5", "mac.local"], port: 7433)],
            actor: actor, credentialID: "5f0c2a9e-7b1d", token: token, pairingSecret: secret)
    }

    func parsed(_ query: String) throws(PairingCodeError) -> PairingCode {
        try PairingCode(parsing: "openrig-remote://pair?v=1&\(query)")
    }

    @Test(arguments: [
        (Reach.Kind.loopback, ["127.0.0.1", "localhost"]), (.lan, ["192.168.1.5", "mac.local"]),
        (.tailnet, ["100.101.102.103", "mac.tail1234.ts.net"]),
    ])
    func eachKindSurvivesARoundTrip(kind: Reach.Kind, addresses: [String]) throws {
        let original = try code([Reach(kind: kind, addresses: addresses, port: 7433)])
        let decoded = try PairingCode(parsing: original.url.absoluteString)
        #expect(decoded == original)
        #expect(try decoded.reaches == [Reach(kind: kind, addresses: addresses, port: 7433)])
    }

    /// The phone tries reaches, and each reach's addresses, in the order the Mac listed them.
    @Test func twoReachesKeepTheirOrderAndTheSecret() throws {
        let reaches = [
            try Reach(kind: .lan, addresses: ["mac.local", "10.0.0.7"], port: 52_100),
            try Reach(kind: .tailnet, addresses: ["100.64.0.9"], port: 7433),
        ]
        let original = try code(reaches, actor: "human-a+b@external", secret: "s3cret+/=")
        let decoded = try PairingCode(parsing: original.url.absoluteString)
        #expect(decoded == original)
        #expect(decoded.reaches.map(\.kind) == [.lan, .tailnet])
        #expect(decoded.reaches[0].addresses == ["mac.local", "10.0.0.7"])
        #expect(decoded.actor == "human-a+b@external")
        #expect(decoded.pairingSecret == "s3cret+/=")
    }

    @Test func noSecretRoundTripsAsNone() throws {
        let decoded = try PairingCode(parsing: code().url.absoluteString)
        #expect(decoded.pairingSecret == nil)
    }

    @Test func linkUsesTheRemoteScheme() throws {
        let url = try code().url
        #expect(url.scheme == "openrig-remote")
        #expect(url.host() == "pair")
    }

    @Test func pastedLinkMayHaveSurroundingWhitespace() throws {
        let original = try code()
        #expect(try PairingCode(parsing: "  \(original.url.absoluteString)\n") == original)
    }

    @Test func addressesAreLowercased() throws {
        let reach = try Reach(kind: .lan, addresses: ["Artems-Mac.LOCAL"], port: 7433)
        #expect(reach.addresses == ["artems-mac.local"])
    }

    /// A newer Mac may add a kind this phone doesn't know: use the kinds it does know.
    @Test func skipsAnUnknownKindBesideAKnownOne() throws {
        let decoded = try parsed("reach=relay-v2:9:fd00::1,x&\(lan)&reach=bluetooth&\(rest)")
        #expect(try decoded.reaches == [Reach(kind: .lan, addresses: ["192.168.1.5"], port: 7433)])
    }

    @Test func onlyUnknownKindsIsRefused() {
        #expect(throws: PairingCodeError.noKnownReach) { try parsed("reach=relay-v2:9:x&reach=bluetooth&\(rest)") }
    }

    @Test(arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.5", "mac.local", "my-mac-2.local"])
    func lanAcceptsPrivateAddressesAndLocalNames(address: String) throws {
        #expect(try Reach(kind: .lan, addresses: [address], port: 7433).addresses == [address])
    }

    /// A public address or another kind's address under `lan` would send the token somewhere else.
    @Test(arguments: [
        "8.8.8.8", "172.32.0.1", "192.169.0.1", "11.0.0.1", "100.64.0.1", "127.0.0.1", "example.com", ".local",
        "mac.local.evil.com", "fd7a:115c:a1e0::1", "mac,x.local", "192.168.1", "192.168.1.256",
    ])
    func lanRefusesOtherAddresses(address: String) {
        #expect(throws: PairingCodeError.unsupportedHost(address)) {
            try Reach(kind: .lan, addresses: [address], port: 7433)
        }
    }

    @Test(arguments: ["100.64.0.1", "100.127.255.254", "mac.tail1234.ts.net"])
    func tailnetAcceptsItsAddresses(address: String) throws {
        #expect(try Reach(kind: .tailnet, addresses: [address], port: 7433).addresses == [address])
    }

    /// The iOS app's ATS exceptions allow tailnet IPv4 and *.ts.net, not the Tailscale IPv6.
    @Test(arguments: [
        "fd7a:115c:a1e0::1", "100.63.255.255", "100.128.0.1", "192.168.1.5", "ts.net.evil.com", ".ts.net",
    ])
    func tailnetRefusesOtherAddresses(address: String) {
        #expect(throws: PairingCodeError.unsupportedHost(address)) {
            try Reach(kind: .tailnet, addresses: [address], port: 7433)
        }
    }

    @Test(arguments: ["192.168.1.5", "127.0.0.2", "mac.local"])
    func loopbackRefusesOtherAddresses(address: String) {
        #expect(throws: PairingCodeError.unsupportedHost(address)) {
            try Reach(kind: .loopback, addresses: [address], port: 7433)
        }
    }

    @Test func aPublicAddressInALinkIsRefused() {
        #expect(throws: PairingCodeError.unsupportedHost("8.8.8.8")) {
            try parsed("reach=lan:7433:192.168.1.5,8.8.8.8&\(rest)")
        }
    }

    @Test func refusesANewerVersion() throws {
        let link = try code().url.absoluteString.replacingOccurrences(of: "v=1", with: "v=2")
        #expect(throws: PairingCodeError.newerVersion(2)) { try PairingCode(parsing: link) }
    }

    @Test func ignoresUnknownFieldsOfTheSameVersion() throws {
        let original = try code()
        #expect(try PairingCode(parsing: original.url.absoluteString + "&label=Phone") == original)
    }

    @Test(arguments: [
        "", "not a link", "https://pair?v=1", "openrig-remote://other?v=1",
        "openrig-remote://pair?reach=lan:7433:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=x&reach=lan:7433:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=0&reach=lan:7433:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:0:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:70000:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:x:192.168.1.5&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:7433&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:7433:&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5&actor=nobody&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5&actor=a@b&credential=&token=orapp_x",
        "openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5&actor=a@b&credential=c&token=secret",
        "openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5&actor=a@b&credential=c",
        "openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5&actor=a@b&credential=c&token=orapp_x&secret=",
    ])
    func refusesMalformedInput(text: String) {
        #expect {
            try PairingCode(parsing: text)
        } throws: { error in
            if case PairingCodeError.malformed = error { true } else { false }
        }
    }

    @Test func refusesNoReaches() {
        #expect(throws: PairingCodeError.malformed("reach")) {
            try PairingCode(reaches: [], actor: "a@b", credentialID: "c", token: token)
        }
    }

    @Test func descriptionHidesTheTokenAndTheSecret() throws {
        let original = try code(secret: "pairing-secret-1")
        var dumped = ""
        dump(original, to: &dumped)
        for shown in [String(describing: original), String(reflecting: original), dumped] {
            #expect(!shown.contains(token))
            #expect(!shown.contains("pairing-secret-1"))
        }
        #expect(String(describing: original).contains("mac.local"))
    }
}

@Suite struct DaemonBindTests {
    @Test func recordedHealthzBindsLoopbackOnly() throws {
        let health: DaemonHealth = try fixture("healthz")
        let bind = try #require(health.bind)
        #expect(bind.hosts == ["127.0.0.1"])
        #expect(bind.tailscaleDetected == false)
        #expect(bind.tailnetHost == nil)
    }

    @Test func tailnetHostIsTheIPv4NotTheIPv6() {
        let bind = DaemonHealth.Bind(hosts: ["127.0.0.1", "fd7a:115c:a1e0::1", "100.101.102.103"])
        #expect(bind.tailnetHost == "100.101.102.103")
    }
}

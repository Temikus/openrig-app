import Foundation
import Testing

@testable import RigModel

@Suite struct PairingCodeTests {
    let token = "orapp_" + String(repeating: "ab", count: 32)

    func code(host: String = "100.101.102.103", actor: String = "artem@external") throws -> PairingCode {
        try PairingCode(host: host, port: 7433, actor: actor, credentialID: "5f0c2a9e-7b1d", token: token)
    }

    @Test func survivesARoundTrip() throws {
        let original = try code(actor: "human-a+b@external")
        let decoded = try PairingCode(parsing: original.url.absoluteString)
        #expect(decoded == original)
        #expect(decoded.daemonURL == URL(string: "http://100.101.102.103:7433"))
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

    @Test(arguments: [
        "100.64.0.1", "100.127.255.254", "mac.tail1234.ts.net", "Mac.Tail1234.TS.NET", "127.0.0.1", "localhost",
    ])
    func acceptsTheHostsTheAppMayReach(host: String) throws {
        let decoded = try PairingCode(parsing: code(host: host).url.absoluteString)
        #expect(decoded.host == host.lowercased())
    }

    /// The iOS app's ATS exceptions allow only tailnet IPv4, *.ts.net and loopback.
    @Test(arguments: [
        "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0::1]", "100.63.255.255", "100.128.0.1", "192.168.1.5", "ts.net.evil.com",
        "example.com",
    ])
    func refusesOtherHosts(host: String) {
        #expect(throws: PairingCodeError.unsupportedHost(host.lowercased())) { try code(host: host) }
    }

    @Test func refusesALinkCarryingTheTailscaleIPv6() throws {
        var parts = try #require(URLComponents(url: code().url, resolvingAgainstBaseURL: false))
        parts.queryItems = parts.queryItems?.map {
            $0.name == "host" ? URLQueryItem(name: "host", value: "fd7a:115c:a1e0::1") : $0
        }
        #expect(throws: PairingCodeError.unsupportedHost("fd7a:115c:a1e0::1")) {
            try PairingCode(parsing: parts.url!.absoluteString)
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
        "openrig-remote://pair?host=100.64.0.1&port=7433&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=x&host=100.64.0.1&port=7433&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=0&host=100.64.0.1&port=7433&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=0&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=70000&actor=a@b&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=7433&actor=nobody&credential=c&token=orapp_x",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=7433&actor=a@b&credential=&token=orapp_x",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=7433&actor=a@b&credential=c&token=secret",
        "openrig-remote://pair?v=1&host=100.64.0.1&port=7433&actor=a@b&credential=c",
    ])
    func refusesMalformedInput(text: String) {
        #expect {
            try PairingCode(parsing: text)
        } throws: { error in
            if case PairingCodeError.malformed = error { true } else { false }
        }
    }

    @Test func descriptionHidesTheToken() throws {
        let original = try code()
        #expect(!String(describing: original).contains(token))
        #expect(!String(reflecting: original).contains(token))
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

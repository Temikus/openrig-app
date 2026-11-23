import Foundation

/// What the Mac shows as a QR code and a link, and the phone reads to pair:
/// `openrig-remote://pair?v=1&host=…&port=…&actor=…&credential=…&token=…`.
/// It carries a live app token. Keep it out of logs; `description` leaves the token out.
public struct PairingCode: Sendable, Equatable {
    public static let version = 1
    public static let scheme = "openrig-remote"

    /// The daemon's tailnet address, or loopback for the simulator. Always lowercased.
    public var host: String
    public var port: Int
    /// The person the phone answers as, e.g. `artem@external`.
    public var actor: String
    public var credentialID: String
    public var token: String

    public init(host: String, port: Int, actor: String, credentialID: String, token: String) throws(PairingCodeError) {
        let host = host.lowercased()
        guard Self.isReachable(host) else { throw .unsupportedHost(host) }
        guard (1...65535).contains(port) else { throw .malformed("port \(port)") }
        guard actor.contains("@") else { throw .malformed("actor") }
        guard !credentialID.isEmpty else { throw .malformed("credential") }
        guard token.hasPrefix("orapp_"), token.count > "orapp_".count else { throw .malformed("token") }
        self.host = host
        self.port = port
        self.actor = actor
        self.credentialID = credentialID
        self.token = token
    }

    /// Reads a scanned or pasted link. Fields this version doesn't know are ignored.
    public init(parsing text: String) throws(PairingCodeError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), parts.scheme == Self.scheme, parts.host == "pair" else {
            throw .malformed("not an OpenRig pairing link")
        }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] where fields[item.name] == nil { fields[item.name] = item.value }
        guard let raw = fields["v"], let version = Int(raw), version >= 1 else { throw .malformed("version") }
        guard version <= Self.version else { throw .newerVersion(version) }
        guard let host = fields["host"], let port = fields["port"].flatMap(Int.init), let actor = fields["actor"],
            let credential = fields["credential"], let token = fields["token"]
        else { throw .malformed("missing field") }
        try self.init(host: host, port: port, actor: actor, credentialID: credential, token: token)
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)), URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "actor", value: actor),
            URLQueryItem(name: "credential", value: credentialID), URLQueryItem(name: "token", value: token),
        ]
        // URLComponents leaves "+" alone, which form decoders read as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    public var daemonURL: URL { URL(string: "http://\(host):\(port)")! }

    /// The hosts the iOS app's ATS exceptions allow (project.yml): tailnet IPv4, `*.ts.net` and loopback.
    /// Tailscale's IPv6 (fd7a:…) is not among them.
    public static func isReachable(_ host: String) -> Bool {
        isTailnet(host) || host == "127.0.0.1" || host == "localhost"
    }

    /// A Tailscale address: IPv4 in 100.64.0.0/10, or a MagicDNS name.
    public static func isTailnet(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") { return host.count > ".ts.net".count }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard octets.count == 4, let first = octets[0], let second = octets[1], octets[2] != nil, octets[3] != nil
        else { return false }
        return first == 100 && (64...127).contains(second)
    }
}

extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PairingCode(\(actor) at \(host):\(port), credential \(credentialID))" }
    public var debugDescription: String { description }
}

public enum PairingCodeError: Error, Sendable, Equatable {
    case malformed(String)
    /// Made by a newer Mac app; this phone app needs an update.
    case newerVersion(Int)
    /// A host the phone app is not allowed to reach over plain HTTP.
    case unsupportedHost(String)
}

import Foundation

/// What the Mac shows as a QR code and a link, and the phone reads to pair:
/// `openrig-remote://pair?v=1&reach=lan:7433:192.168.1.5,mac.local&actor=…&credential=…&token=…&secret=…`.
/// It carries a live app token. Keep it out of logs; `description` leaves the token and the secret out.
public struct PairingCode: Sendable, Equatable {
    public static let version = 1
    public static let scheme = "openrig-remote"

    /// The ways to reach the Mac, in the order the phone tries them. Says nothing about what listens there.
    public var reaches: [Reach]
    /// The person the phone answers as, e.g. `artem@external`.
    public var actor: String
    public var credentialID: String
    public var token: String
    /// Set when the link to the Mac needs one, e.g. a relay's shared secret.
    public var pairingSecret: String?
    /// The Mac's name to show, e.g. "Artem's MacBook Pro". Nil when the Mac didn't say.
    public var name: String?

    public init(
        reaches: [Reach], actor: String, credentialID: String, token: String, pairingSecret: String? = nil,
        name: String? = nil
    ) throws(PairingCodeError) {
        guard !reaches.isEmpty else { throw .malformed("reach") }
        guard actor.contains("@") else { throw .malformed("actor") }
        guard !credentialID.isEmpty else { throw .malformed("credential") }
        guard token.hasPrefix("orapp_"), token.count > "orapp_".count else { throw .malformed("token") }
        guard pairingSecret?.isEmpty != true else { throw .malformed("secret") }
        self.reaches = reaches
        self.actor = actor
        self.credentialID = credentialID
        self.token = token
        self.pairingSecret = pairingSecret
        self.name = name?.isEmpty == true ? nil : name
    }

    /// Reads a scanned or pasted link. Fields and kinds of reach this version doesn't know are skipped.
    public init(parsing text: String) throws(PairingCodeError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), parts.scheme == Self.scheme, parts.host == "pair" else {
            throw .malformed("not an OpenRig pairing link")
        }
        let items = parts.queryItems ?? []
        var fields: [String: String] = [:]
        for item in items where fields[item.name] == nil { fields[item.name] = item.value ?? "" }
        guard let raw = fields["v"], let version = Int(raw), version >= 1 else { throw .malformed("version") }
        guard version <= Self.version else { throw .newerVersion(version) }

        var reaches: [Reach] = []
        var skipped = false
        for item in items where item.name == "reach" {
            if let reach = try Reach(wire: item.value ?? "") { reaches.append(reach) } else { skipped = true }
        }
        if reaches.isEmpty { throw skipped ? .noKnownReach : .malformed("missing field") }
        guard let actor = fields["actor"], let credential = fields["credential"], let token = fields["token"] else {
            throw .malformed("missing field")
        }
        try self.init(
            reaches: reaches, actor: actor, credentialID: credential, token: token, pairingSecret: fields["secret"],
            name: fields["name"])
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        var items = [URLQueryItem(name: "v", value: String(Self.version))]
        items += reaches.map { URLQueryItem(name: "reach", value: $0.wire) }
        items += [
            URLQueryItem(name: "actor", value: actor), URLQueryItem(name: "credential", value: credentialID),
            URLQueryItem(name: "token", value: token),
        ]
        if let pairingSecret { items.append(URLQueryItem(name: "secret", value: pairingSecret)) }
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        parts.queryItems = items
        // URLComponents leaves "+" alone, which form decoders read as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}

extension PairingCode {
    /// One way to reach the Mac: a kind, the addresses to try in order, and a port.
    public struct Reach: Sendable, Equatable {
        public var kind: Kind
        /// Lowercased.
        public var addresses: [String]
        public var port: Int

        public enum Kind: String, Sendable, CaseIterable {
            /// This Mac itself, for the simulator.
            case loopback
            /// The home network: private IPv4 and `.local` names.
            case lan
            /// Tailscale: IPv4 in 100.64.0.0/10 and MagicDNS names. Not its IPv6, which the iOS app's ATS blocks.
            case tailnet

            public func accepts(_ address: String) -> Bool {
                let address = address.lowercased()
                switch self {
                case .loopback:
                    return address == "127.0.0.1" || address == "localhost"
                case .lan:
                    if let ip = Self.ipv4(address) {
                        return ip[0] == 10 || (ip[0] == 172 && (16...31).contains(ip[1]))
                            || (ip[0] == 192 && ip[1] == 168)
                    }
                    return Self.isName(address, under: "local")
                case .tailnet:
                    if let ip = Self.ipv4(address) { return ip[0] == 100 && (64...127).contains(ip[1]) }
                    return Self.isName(address, under: "ts.net")
                }
            }

            /// Digits only, and no leading zero: some parsers read `010` as octal 8.
            public static func ipv4(_ text: String) -> [UInt8]? {
                let parts = text.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 4,
                    parts.allSatisfy({ part in
                        (1...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
                            && (part.count == 1 || part.first != "0")
                    })
                else { return nil }
                let octets = parts.compactMap { UInt8($0) }
                return octets.count == 4 ? octets : nil
            }

            /// A DNS name ending in `suffix`, with at least one label before it.
            static func isName(_ text: String, under suffix: String) -> Bool {
                guard text.hasSuffix("." + suffix), text.count > suffix.count + 1 else { return false }
                return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                    !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                }
            }
        }

        public init(kind: Kind, addresses: [String], port: Int) throws(PairingCodeError) {
            guard !addresses.isEmpty else { throw .malformed("reach addresses") }
            guard (1...65535).contains(port) else { throw .malformed("port \(port)") }
            let addresses = addresses.map { $0.lowercased() }
            if let refused = addresses.first(where: { !kind.accepts($0) }) { throw .unsupportedHost(refused) }
            self.kind = kind
            self.addresses = addresses
            self.port = port
        }

        /// `kind:port:address,address`. The port comes first so a later kind's addresses may hold colons.
        var wire: String { "\(kind.rawValue):\(port):\(addresses.joined(separator: ","))" }

        /// Nil for a kind this version doesn't know.
        init?(wire: String) throws(PairingCodeError) {
            let parts = wire.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard !parts[0].isEmpty else { throw .malformed("reach") }
            guard let kind = Kind(rawValue: parts[0].lowercased()) else { return nil }
            guard parts.count == 3, let port = Int(parts[1]) else { throw .malformed("reach") }
            let addresses = parts[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !addresses.contains(where: \.isEmpty) else { throw .malformed("reach addresses") }
            try self.init(kind: kind, addresses: addresses, port: port)
        }
    }
}

extension PairingCode.Reach: CustomStringConvertible {
    public var description: String { "\(kind.rawValue) \(addresses.joined(separator: ",")) port \(port)" }
}

/// Leaves the token and the secret out of `print`, `debugPrint` and `dump`.
extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "PairingCode(\(actor) via \(reaches.map(\.description).joined(separator: "; ")), credential \(credentialID))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "reaches": reaches, "actor": actor, "credentialID": credentialID,
                "hasPairingSecret": pairingSecret != nil,
            ])
    }
}

public enum PairingCodeError: Error, Sendable, Equatable {
    case malformed(String)
    /// Made by a newer Mac app; this phone app needs an update.
    case newerVersion(Int)
    /// Every reach is of a kind this phone app doesn't know; it needs an update.
    case noKnownReach
    /// An address its reach's kind doesn't cover, e.g. a public address under `lan`.
    case unsupportedHost(String)
}

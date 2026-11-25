import Foundation
import RigModel

/// Where the Mac's relay listens, and the one phone's secret for it.
public struct RelayReach: Sendable, Equatable {
    /// The Mac's `.local` name first (it survives a new Wi-Fi address), then its home-network addresses.
    public var addresses: [String]
    public var port: UInt16
    public var secret: Data

    public init(addresses: [String], port: UInt16, secret: Data) {
        self.addresses = addresses
        self.port = port
        self.secret = secret
    }
}

extension PairingCode {
    /// The code the Mac's Phone tab shows. Loopback first: the simulator on this Mac reaches the daemon directly.
    /// With the relay listening, a `lan` reach to it follows, with this phone's secret; without it, a real phone has
    /// no way in.
    public static func forThisMac(
        credential: AppCredential, actor: String, daemon: URL, relay: RelayReach? = nil, name: String? = nil
    ) throws(PairingCodeError) -> PairingCode {
        let host = daemon.host()?.lowercased() ?? ""
        guard Reach.Kind.loopback.accepts(host) else { throw .unsupportedHost(host) }
        var reaches = [try Reach(kind: .loopback, addresses: [host], port: daemon.port ?? 7433)]
        if let relay, !relay.addresses.isEmpty {
            reaches.append(try Reach(kind: .lan, addresses: relay.addresses, port: Int(relay.port)))
        }
        return try PairingCode(
            reaches: reaches, actor: actor, credentialID: credential.id, token: credential.token,
            pairingSecret: relay.map { RelayLink.encode($0.secret) }, name: name)
    }
}

extension RelayLink {
    /// A secret as it travels in the pairing link: base64url, no padding.
    public static func encode(_ secret: Data) -> String {
        secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil unless the text is base64url for exactly 256 bits.
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }
}

/// A phone this Mac paired. The daemon has no route to list credentials, so the Mac keeps its own record. No token.
public struct PairedPhone: Codable, Sendable, Equatable, Identifiable {
    /// The credential's id, which Unpair revokes.
    public var id: String
    /// The phone's own name, once the relay learns it (task 8). Empty until then.
    public var name: String
    /// The person the phone answers as.
    public var actor: String
    public var paired: Date
    /// The daemon that issued the credential, as "host:port". Only that daemon can revoke it.
    public var daemon: String

    public init(id: String, name: String, actor: String, paired: Date, daemon: URL) {
        self.id = id
        self.name = name
        self.actor = actor
        self.paired = paired
        self.daemon = Self.key(daemon)
    }

    /// "host:port", so a trailing slash, a default port or `localhost` doesn't make one daemon look like two.
    public static func key(_ daemon: URL) -> String {
        let host = daemon.host()?.lowercased() ?? ""
        return "\(host == "localhost" ? "127.0.0.1" : host):\(daemon.port ?? 7433)"
    }

    private enum CodingKeys: String, CodingKey { case id, name, actor, paired, daemon }

    /// Fields added after the first record default, so an older row still reads. A row from before `daemon` was
    /// stored was paired on this Mac's own daemon: pairing refused any other.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        actor = try c.decode(String.self, forKey: .actor)
        paired = try c.decode(Date.self, forKey: .paired)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        daemon = try c.decodeIfPresent(String.self, forKey: .daemon) ?? "127.0.0.1:7433"
    }

    /// Until a phone is seen to connect, the row is the code that was shown: "Code from 24 Nov, 14:01".
    public var title: String {
        name.isEmpty ? "Code from \(paired.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" : name
    }
}

/// Why the Phone tab won't issue or revoke a credential.
public enum PairingRefusal: Error, Sendable, Equatable {
    /// OPENRIG_DEBUG_PHONE's made-up state talks to no daemon.
    case madeUp
    /// The phone's credential lives on another daemon, as "host:port".
    case otherDaemon(String)
    /// The relay's switch is off: a phone on the Wi-Fi has no way in.
    case relayOff
    /// The Mac has no home-network address or `.local` name to put in the code.
    case noWiFiAddress

    public var message: String {
        switch self {
        case .madeUp: "A made-up state (OPENRIG_DEBUG_PHONE): no credential is issued or revoked."
        case .otherDaemon(let daemon): "Paired on the daemon at \(daemon). Connect to it to unpair."
        case .relayOff: "Turn on “Let paired phones connect” first, or the phone has no way in."
        case .noWiFiAddress: "This Mac has no Wi-Fi address a phone could reach. Join the Wi-Fi, then try again."
        }
    }
}

/// The Mac's record of paired phones, newest first, saved as JSON.
public struct PairedPhones: Sendable, Equatable {
    public private(set) var list: [PairedPhone] = []
    /// A made-up state: shown, never saved, and never sent to a daemon.
    public var isMadeUp = false

    public init() {}

    /// The phones paired on this daemon; the others can't be unpaired from here.
    public func list(for daemon: URL) -> [PairedPhone] {
        let key = PairedPhone.key(daemon)
        return list.filter { $0.daemon == key }
    }

    public var refusesIssue: PairingRefusal? { isMadeUp ? .madeUp : nil }

    /// Before a credential is issued: a code needs the relay on and a Wi-Fi address to name. Held to loopback (the
    /// simulator on this Mac), the loopback reach is enough.
    public func refusesPairing(relayOn: Bool, heldToLoopback: Bool, wifiAddresses: [String]) -> PairingRefusal? {
        if let refusal = refusesIssue { return refusal }
        if !relayOn { return .relayOff }
        return heldToLoopback || !wifiAddresses.isEmpty ? nil : .noWiFiAddress
    }

    /// After it is issued and the relay restarted: no code without a way in. The caller revokes the credential.
    public func refusesCode(relay: RelayReach?, heldToLoopback: Bool) -> PairingRefusal? {
        relay != nil || heldToLoopback ? nil : .noWiFiAddress
    }

    public func refusesRevoke(_ phone: PairedPhone, at daemon: URL) -> PairingRefusal? {
        if isMadeUp { return .madeUp }
        return phone.daemon == PairedPhone.key(daemon) ? nil : .otherDaemon(phone.daemon)
    }

    /// A record that doesn't decode reads as empty: the phones are still paired at the daemon, but Unpair can't
    /// reach them from here.
    public init(data: Data?) {
        list = data.flatMap { try? JSONDecoder().decode([PairedPhone].self, from: $0) } ?? []
    }

    public var data: Data { (try? JSONEncoder().encode(list)) ?? Data("[]".utf8) }

    public mutating func add(_ phone: PairedPhone) {
        list.removeAll { $0.id == phone.id }
        list.insert(phone, at: 0)
    }

    public mutating func remove(id: PairedPhone.ID) {
        list.removeAll { $0.id == id }
    }
}

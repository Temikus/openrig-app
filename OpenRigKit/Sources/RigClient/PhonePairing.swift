import Foundation
import RigModel

extension PairingCode {
    /// The code the Mac's Phone tab shows. Until the relay listens on the Wi-Fi, the only way in is loopback, which
    /// only the simulator on this Mac shares: the code points it at the daemon directly.
    public static func forThisMac(credential: AppCredential, actor: String, daemon: URL) throws(PairingCodeError)
        -> PairingCode
    {
        let host = daemon.host()?.lowercased() ?? ""
        guard Reach.Kind.loopback.accepts(host) else { throw .unsupportedHost(host) }
        let reach = try Reach(kind: .loopback, addresses: [host], port: daemon.port ?? 7433)
        return try PairingCode(reaches: [reach], actor: actor, credentialID: credential.id, token: credential.token)
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

    /// "host:port", so a trailing slash or a default port doesn't make one daemon look like two.
    public static func key(_ daemon: URL) -> String {
        "\(daemon.host()?.lowercased() ?? ""):\(daemon.port ?? 7433)"
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

    public var message: String {
        switch self {
        case .madeUp: "A made-up state (OPENRIG_DEBUG_PHONE): no credential is issued or revoked."
        case .otherDaemon(let daemon): "Paired on the daemon at \(daemon). Connect to it to unpair."
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

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
    public var name: String
    /// The person the phone answers as.
    public var actor: String
    public var paired: Date

    public init(id: String, name: String, actor: String, paired: Date) {
        self.id = id
        self.name = name
        self.actor = actor
        self.paired = paired
    }
}

/// The Mac's record of paired phones, newest first, saved as JSON.
public struct PairedPhones: Sendable, Equatable {
    public private(set) var list: [PairedPhone] = []

    public init() {}

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

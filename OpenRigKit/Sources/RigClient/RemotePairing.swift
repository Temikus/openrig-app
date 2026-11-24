import Foundation
import RigModel
import Security
import Synchronization

/// What the phone keeps after pairing. It holds the token, so it is stored whole in the Keychain.
public struct RemotePairing: Sendable, Equatable {
    public var code: PairingCode
    public var pairedAt: Date

    public init(code: PairingCode, pairedAt: Date) {
        self.code = code
        self.pairedAt = pairedAt
    }
}

/// Stored as the pairing link, so the Keychain item reads back through the same checks as a scanned code.
extension RemotePairing: Codable {
    private enum CodingKeys: String, CodingKey { case link, pairedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try PairingCode(parsing: c.decode(String.self, forKey: .link))
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code.url.absoluteString, forKey: .link)
        try c.encode(pairedAt, forKey: .pairedAt)
    }
}

/// Leaves the token out of `print`, `debugPrint` and `dump`.
extension RemotePairing: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RemotePairing(\(code), paired \(pairedAt))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["code": code, "pairedAt": pairedAt]) }
}

public protocol PairingStore: Sendable {
    func load() throws -> RemotePairing?
    func save(_ pairing: RemotePairing) throws
    func delete() throws
}

/// One generic-password item, readable after the first unlock and never synced or restored to another device.
public struct KeychainPairingStore: PairingStore {
    public var service: String

    public init(service: String = "dev.openrig.Remote.pairing") { self.service = service }

    public struct Failure: Error, Equatable { public var status: OSStatus }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "pairing"]
    }

    public func load() throws -> RemotePairing? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(RemotePairing.self, from: data)
    }

    public func save(_ pairing: RemotePairing) throws {
        try delete()
        var q = query
        q[kSecValueData] = try JSONEncoder().encode(pairing)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// For tests and previews.
public final class MemoryPairingStore: PairingStore {
    private let stored: Mutex<RemotePairing?>

    public init(_ pairing: RemotePairing? = nil) { stored = Mutex(pairing) }

    public func load() throws -> RemotePairing? { stored.withLock { $0 } }
    public func save(_ pairing: RemotePairing) throws { stored.withLock { $0 = pairing } }
    public func delete() throws { stored.withLock { $0 = nil } }
}

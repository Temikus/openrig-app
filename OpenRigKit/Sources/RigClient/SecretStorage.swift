import Foundation
import Synchronization

/// Where the Mac app keeps its secrets: the relay's phone keys and the operator token.
public enum SecretStorage: Sendable, Equatable {
    case keychain
    /// Lost on quit. An agent's test copy is signed ad hoc again on every build, so the Keychain would ask the person
    /// on their screen for each read.
    case memory

    /// Memory only for a DEBUG build whose bundle id ends in ".agent".
    public static func choose(bundleID: String?, debug: Bool) -> SecretStorage {
        debug && bundleID?.hasSuffix(".agent") == true ? .memory : .keychain
    }
}

/// Secrets by account, in memory.
public final class MemorySecrets: Sendable {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func read(_ account: String) -> Data? { items.withLock { $0[account] } }
    public func save(_ secret: Data, for account: String) { items.withLock { $0[account] = secret } }
    public func forget(_ account: String) { items.withLock { $0[account] = nil } }
}

import Foundation
import RigClient
import Security

/// This build's secret store. An agent's `.agent` copy never touches the Keychain: see `SecretStorage.memory`.
enum Secrets {
    static let storage: SecretStorage = {
        #if DEBUG
            SecretStorage.choose(bundleID: Bundle.main.bundleIdentifier, debug: true)
        #else
            .keychain
        #endif
    }()

    /// Used only when `storage` is `.memory`.
    static let memory = MemorySecrets()
}

/// The daemon's operator bearer, kept in the login Keychain. Never logged and never written to UserDefaults.
enum OperatorToken {
    private static let service = "dev.openrig.OpenRig"
    private static let account = "operator-token"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        if Secrets.storage == .memory {
            return Secrets.memory.read(account).flatMap { String(data: $0, encoding: .utf8) }
        }
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `token`, or removes it when empty. Returns false if the Keychain refused.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if Secrets.storage == .memory {
            if trimmed.isEmpty {
                Secrets.memory.forget(account)
            } else {
                Secrets.memory.save(Data(trimmed.utf8), for: account)
            }
            return true
        }
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

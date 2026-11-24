import Foundation
import Observation
import RigClient
import RigModel
import Security
import SystemConfiguration

/// Each paired phone's relay secret, in the login Keychain under this app's own bundle id, by credential id.
enum RelaySecrets {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "dev.openrig.OpenRig") + ".relay" }

    private static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    static func read(_ id: String) -> Data? {
        var item: CFTypeRef?
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func save(_ secret: Data, for id: String) -> Bool {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = secret
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Unpair forgets the secret, so a revoked phone can't even finish the handshake.
    static func forget(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

/// The relay for paired phones. It listens only while the switch is on, the daemon runs on this Mac, and a phone on
/// this daemon has a secret; otherwise nothing listens.
@MainActor @Observable
final class RelayStore {
    enum State: Equatable {
        case off(String)
        case listening(host: String, port: UInt16)
        case failed(String)
    }

    private(set) var state = State.off("No phone is paired.")
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var server: RelayServer?
    @ObservationIgnored private var running: (keys: [String: Data], daemon: URL)?
    private static let enabledKey = "relayEnabled"
    /// Tried first; a taken port falls back to a free one.
    static let preferredPort: UInt16 = 7434

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Where the relay binds. OPENRIG_RELAY_LOOPBACK=1 keeps it on 127.0.0.1: seats' copies of the app must never
    /// listen on the Wi-Fi, where macOS can ask the person about the firewall or Local Network, on screen.
    static var bindHost: String {
        ProcessInfo.processInfo.environment["OPENRIG_RELAY_LOOPBACK"] == "1" ? "127.0.0.1" : "0.0.0.0"
    }

    /// Starts, restarts or stops the relay to match the paired phones on `daemon`.
    func refresh(daemon: URL) async {
        let phones = PairedPhones(data: defaults.data(forKey: "pairedPhones")).list(for: daemon)
        let keys = Dictionary(phones.compactMap { phone in RelaySecrets.read(phone.id).map { (phone.id, $0) } }) {
            a, _ in a
        }
        let reason: String? =
            if !enabled { "Off." } else if !PairingCode.Reach.Kind.loopback.accepts(daemon.host() ?? "") {
                "The daemon runs on another machine."
            } else if keys.isEmpty { "No phone is paired." } else { nil }
        if let reason {
            stop()
            state = .off(reason)
            return
        }
        if let running, running.keys == keys, running.daemon == daemon, case .listening = state { return }
        stop()
        let server = RelayServer(
            keys: keys, host: Self.bindHost, port: Self.preferredPort,
            forward: RelayServer.daemonForwarder(daemon))
        do {
            let port = try await server.start()
            self.server = server
            running = (keys, daemon)
            state = .listening(host: Self.bindHost, port: port)
        } catch {
            state = .failed("Couldn't listen for phones: \(error.localizedDescription)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        running = nil
    }

    /// OPENRIG_RELAY_LOOPBACK=1: only the simulator on this Mac can connect, by design.
    var heldToLoopback: Bool { Self.bindHost == "127.0.0.1" }

    /// What a code can name for a phone on the Wi-Fi: this Mac's `.local` name, then its home-network addresses.
    var wifiAddresses: [String] {
        let name = SCDynamicStoreCopyLocalHostName(nil).map { ($0 as String).lowercased() + ".local" }
        return [name].compactMap(\.self).filter(PairingCode.Reach.Kind.lan.accepts) + LocalAddresses.lan()
    }

    /// The pairing code's `lan` reach for one phone, with the relay's port. Nil unless the relay listens on the Wi-Fi
    /// and the Mac has an address to name: otherwise no phone could use the code.
    func reach(for secret: Data) -> RelayReach? {
        guard case .listening(let host, let port) = state, host != "127.0.0.1" else { return nil }
        let addresses = wifiAddresses
        return addresses.isEmpty ? nil : RelayReach(addresses: addresses, port: port, secret: secret)
    }

    /// A phone on the Wi-Fi could connect right now: the same check a code passes before it is shown.
    var usable: Bool { reach(for: Data()) != nil }

    /// What a phone connects to: this Mac's home-network address and Bonjour name, or loopback when held there.
    var address: String? {
        guard case .listening(let host, let port) = state else { return nil }
        if host == "127.0.0.1" { return "127.0.0.1:\(port) (this Mac only)" }
        let lan = LocalAddresses.lan().first.map { "\($0):\(port)" } ?? "port \(port)"
        let name = SCDynamicStoreCopyLocalHostName(nil).map { "\($0 as String).local" }
        return [lan, name.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
    }
}

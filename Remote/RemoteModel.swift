import Foundation
import Observation
import RigClient
import RigModel

enum PairingStep: Hashable {
    case scanner
}

/// The phone's state: the stored pairing, where it stands with the Mac, and the last list it read.
@Observable @MainActor
final class RemoteModel {
    private(set) var pairing: RemotePairing?
    /// Nil until the first check after pairing or launch finishes.
    private(set) var status: RemoteStatus?
    private(set) var checking = false
    /// The last list read. Kept while the Mac is out of reach, marked with `lastReached`.
    private(set) var needs: AppNeedsMe?
    private(set) var lastReached: Date?
    /// Why the last scanned or pasted link didn't pair.
    var pairingError: String?
    /// The pairing flow's pushed screens. The explainer is the root.
    var pairingPath: [PairingStep] = []

    private let store: any PairingStore
    private let connector: RemoteConnector

    init(store: any PairingStore, connector: RemoteConnector) {
        self.store = store
        self.connector = connector
        pairing = try? store.load()
        #if DEBUG
            if DebugHooks.screen == "scanner" { pairingPath = [.scanner] }
        #endif
    }

    static func live() -> RemoteModel {
        RemoteModel(
            store: KeychainPairingStore(),
            connector: RemoteConnector(localNetworkDenied: { await RigClient.localNetworkDenied($0) }))
    }

    var macName: String { pairing?.code.name ?? "Your Mac" }

    /// The endpoint in use, or the first one the code lists.
    var address: String? {
        if case .connected(let endpoint) = status { return endpoint.description }
        return pairing.flatMap { RemoteEndpoint.all(in: $0.code).first?.description }
    }

    /// `artem@external` shows as `artem`.
    var answeringAs: String? { pairing.map { String($0.code.actor.prefix { $0 != "@" }) } }

    /// A link opened from outside the app, waiting for the person's yes.
    var pendingCode: PairingCode?

    /// A scan or paste inside the app: the person chose it, so it pairs at once.
    func pair(link: String) {
        do {
            save(try PairingCode(parsing: link))
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    /// A link from another app or a web page. Anyone can send one, so it pairs only after the person confirms.
    func receive(openedLink link: String) {
        do {
            pendingCode = try PairingCode(parsing: link)
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    func confirmPending() {
        if let pendingCode { save(pendingCode) }
        pendingCode = nil
    }

    private func save(_ code: PairingCode) {
        let new = RemotePairing(code: code, pairedAt: .now)
        do {
            try store.save(new)
        } catch {
            pairingError = "This phone couldn't keep the pairing in its Keychain. Try again."
            return
        }
        pairing = new
        status = nil
        needs = nil
        lastReached = nil
        pairingError = nil
        pairingPath = []
        Task { await refresh() }
    }

    func unpair() {
        try? store.delete()
        pairing = nil
        status = nil
        needs = nil
        lastReached = nil
    }

    func refresh() async {
        guard let pairing, !checking else { return }
        checking = true
        defer { checking = false }
        let outcome = await connector.connect(pairing.code)
        guard self.pairing == pairing else { return }
        var next = outcome.status
        if let client = outcome.client {
            do {
                needs = try await client.needsMe()
                lastReached = .now
            } catch .unpaired {
                next = .unpaired
            } catch {
                next = .unreachable(detail: "\(error)")
            }
        }
        #if DEBUG
            if let forced = DebugHooks.state { next = forced }
        #endif
        status = next
    }

    static func message(for error: PairingCodeError) -> String {
        switch error {
        case .malformed: "That isn't an OpenRig pairing link. Copy the whole link under the code on your Mac."
        case .newerVersion, .noKnownReach: "This link comes from a newer OpenRig. Update this app, then pair again."
        case .unsupportedHost(let host): "This link points to \(host), which this app won't connect to."
        }
    }
}

#if DEBUG
    /// Launch hooks for headless captures, like the Mac app's `OPENRIG_DEBUG_*`. Pass them to `simctl launch` with
    /// the `SIMCTL_CHILD_` prefix.
    enum DebugHooks {
        static var environment: [String: String] { ProcessInfo.processInfo.environment }

        /// `scanner` opens the scanner, `settings` the Settings tab.
        static var screen: String? { environment["OPENRIG_DEBUG_SCREEN"] }

        /// Pairs at launch through `pair(link:)`, as a scanned, pasted or opened link does. `simctl openurl` would
        /// stop at the system's "Open in OpenRig?" confirmation.
        static var pairLink: String? { environment["OPENRIG_DEBUG_PAIR_LINK"] }

        /// Handles a link as `onOpenURL` does: it waits for the person's confirmation.
        static var openedLink: String? { environment["OPENRIG_DEBUG_OPEN_LINK"] }

        /// Replaces the status after each real check, keeping what was read: `unreachable`, `local-network-denied`,
        /// `unpaired`, `unsupported`.
        static var state: RemoteStatus? {
            switch environment["OPENRIG_DEBUG_STATE"] {
            case "unreachable": .unreachable(detail: "Could not connect to the server.")
            case "local-network-denied": .localNetworkDenied
            case "unpaired": .unpaired
            case "unsupported": .unsupportedDaemon
            default: nil
            }
        }
    }
#endif

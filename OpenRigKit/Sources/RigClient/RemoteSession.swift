import Foundation
import Observation
import RigModel

/// The phone's side of a pairing: the stored code, where the phone stands with the Mac, and the last list it read.
@Observable @MainActor
public final class RemoteSession {
    public private(set) var pairing: RemotePairing?
    /// Nil until the first check after pairing or launch finishes.
    public private(set) var status: RemoteStatus?
    public private(set) var checking = false
    /// The last list read. Kept while the Mac is out of reach, marked with `lastReached`.
    public private(set) var needs: AppNeedsMe?
    public private(set) var lastReached: Date?
    /// Why the last link didn't pair, or why Unpair failed.
    public var pairingError: String?
    /// A link opened from outside the app, waiting for the person's yes.
    public var pendingCode: PairingCode?
    /// Replaces the status after each real check, keeping what was read. For headless captures.
    public var statusOverride: RemoteStatus?

    private let store: any PairingStore
    private let connect: @Sendable (PairingCode) async -> RemoteConnector.Outcome

    public init(store: any PairingStore, connect: @escaping @Sendable (PairingCode) async -> RemoteConnector.Outcome) {
        self.store = store
        self.connect = connect
        pairing = try? store.load()
    }

    public convenience init(store: any PairingStore, connector: RemoteConnector) {
        self.init(store: store, connect: { await connector.connect($0) })
    }

    public var macName: String { pairing?.code.name ?? "Your Mac" }

    /// The endpoint in use, or the first one the code lists.
    public var address: String? {
        if case .connected(let endpoint) = status { return endpoint.description }
        return pairing.flatMap { RemoteEndpoint.all(in: $0.code).first?.description }
    }

    /// The asks Needs you lists, or nil when a state screen takes its place. A list read before the Mac went out of
    /// reach stays, marked with `lastReached`.
    public var shownRequests: [AppRequest]? {
        switch status {
        case nil, .unreachable: needs?.requests
        case .connected: needs?.requests ?? []
        case .localNetworkDenied, .unpaired, .unsupportedDaemon, .noSafeAddress: nil
        }
    }

    /// `artem@external` shows as `artem`.
    public var answeringAs: String? { pairing.map { String($0.code.actor.prefix { $0 != "@" }) } }

    /// A scan or paste inside the app: the person chose it, so it pairs at once.
    public func pair(link: String) {
        do {
            save(try PairingCode(parsing: link))
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    /// A link from another app or a web page. Anyone can send one, so it pairs only after the person confirms.
    public func receive(openedLink link: String) {
        do {
            pendingCode = try PairingCode(parsing: link)
        } catch {
            pairingError = Self.message(for: error)
        }
    }

    public func confirmPending() {
        if let pendingCode { save(pendingCode) }
        pendingCode = nil
    }

    /// A failed save leaves the old pairing in place.
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
        Task { await refresh() }
    }

    /// If the Keychain won't let go, the token is still on the phone: say so and stay paired.
    public func unpair() {
        do {
            try store.delete()
        } catch {
            pairingError =
                "This phone couldn't remove the pairing from its Keychain, so it still holds the key. Try again, or delete the app."
            return
        }
        pairing = nil
        status = nil
        needs = nil
        lastReached = nil
        pairingError = nil
    }

    /// Checks the current pairing. If the pairing changes while a check runs, that check's result is dropped and the
    /// new pairing is checked, so a new pairing never waits on an old one.
    public func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        while let current = pairing, await !check(current) {}
    }

    /// False when the pairing changed underneath, so nothing was applied.
    private func check(_ checked: RemotePairing) async -> Bool {
        let outcome = await connect(checked.code)
        guard pairing == checked else { return false }
        var next = outcome.status
        var read: AppNeedsMe?
        if let client = outcome.client {
            do {
                read = try await client.needsMe()
            } catch .unpaired {
                next = .unpaired
            } catch {
                next = .unreachable(detail: "\(error)")
            }
            guard pairing == checked else { return false }
        }
        if let read {
            needs = read
            lastReached = .now
        }
        status = statusOverride ?? next
        return true
    }

    public static func message(for error: PairingCodeError) -> String {
        switch error {
        case .malformed: "That isn't an OpenRig pairing link. Copy the whole link under the code on your Mac."
        case .newerVersion, .noKnownReach: "This link comes from a newer OpenRig. Update this app, then pair again."
        case .unsupportedHost(let host): "This link points to \(host), which this app won't connect to."
        }
    }
}

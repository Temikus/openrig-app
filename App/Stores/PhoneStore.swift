import Foundation
import Observation
import RigClient
import RigModel

/// Pairing for Settings › Phone: issues a phone's credential, holds its code while shown, and keeps the record of
/// paired phones that Unpair revokes.
@MainActor @Observable
final class PhoneStore {
    enum Code: Equatable {
        case hidden
        case issuing
        /// Holds a live token: drop it as soon as the code closes.
        case showing(PairingCode)
        case failed(String)
    }

    private(set) var phones: PairedPhones
    private(set) var code = Code.hidden
    /// Unpair's or Cancel Code's error, by phone.
    private(set) var unpairErrors: [PairedPhone.ID: String] = [:]
    private(set) var unpairing: Set<PairedPhone.ID> = []

    private let defaults: UserDefaults
    private static let key = "pairedPhones"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        phones = PairedPhones(data: defaults.data(forKey: Self.key))
    }

    #if DEBUG
        /// OPENRIG_DEBUG_PHONE=pairing|paired opens the tab in that state, for captures without a press. Made up and
        /// in memory only: `PairedPhones.isMadeUp` stops every issue and revoke, nothing is saved, and the code's token
        /// is fake.
        private init(debug state: String) {
            defaults = .standard
            phones = PairedPhones()
            phones.isMadeUp = true
            let daemon = URL(string: "http://127.0.0.1:7433")!
            let day: TimeInterval = 86400
            if state == "paired" || state == "pairing" {
                phones.add(
                    PairedPhone(id: "debug-2", name: "", actor: "you@external", paired: .now - 20 * day, daemon: daemon)
                )
                phones.add(
                    PairedPhone(id: "debug-1", name: "", actor: "you@external", paired: .now - day, daemon: daemon))
            }
            if state == "pairing" {
                let json = #"""
                    {"credentialId": "debug-1", "appId": "openrig-remote", "scope": {"actors": ["you@external"]},
                     "token": "orapp_DEBUGnotARealTokenDEBUGnotARealTokenDEBUG"}
                    """#
                if let credential = try? JSONDecoder().decode(AppCredential.self, from: Data(json.utf8)),
                    let code = try? PairingCode.forThisMac(
                        credential: credential, actor: "you@external", daemon: daemon)
                {
                    self.code = .showing(code)
                }
            }
        }

        static func launch() -> PhoneStore {
            ProcessInfo.processInfo.environment["OPENRIG_DEBUG_PHONE"].map { PhoneStore(debug: $0) } ?? PhoneStore()
        }
    #endif

    /// Issues a credential that answers as `actor` and shows its code. The row is recorded at once: the credential
    /// exists from here on, and the record is the only way to revoke it.
    func pair(daemon: URL, bearer: String?, actor: String, relay: RelayStore) async {
        if let refusal = phones.refusesPairing(
            relayOn: relay.enabled, heldToLoopback: relay.heldToLoopback, wifiAddresses: relay.wifiAddresses)
        {
            code = .failed(refusal.message)
            return
        }
        let host = daemon.host() ?? daemon.absoluteString
        guard PairingCode.Reach.Kind.loopback.accepts(host) else {
            code = .failed(Self.elsewhere(host))
            return
        }
        code = .issuing
        do {
            let credential = try await DaemonHTTP(baseURL: daemon, timeout: 5, bearer: bearer)
                .issueAppCredential(for: [actor])
            let phone = PairedPhone(id: credential.id, name: "", actor: actor, paired: .now, daemon: daemon)
            phones.add(phone)
            save()
            // The phone's own key to the relay. The relay restarts with it before the code is drawn, so the code
            // carries the port it actually got.
            let secret = RelayLink.newSecret()
            RelaySecrets.save(secret, for: credential.id)
            await relay.refresh(daemon: daemon)
            let reach = relay.reach(for: secret)
            if let refusal = phones.refusesCode(relay: reach, heldToLoopback: relay.heldToLoopback) {
                // No way in after all (the relay couldn't listen on the Wi-Fi): take back what was just issued.
                await unpair(phone, daemon: daemon, bearer: bearer)
                await relay.refresh(daemon: daemon)
                code = .failed(phones.list.contains { $0.id == phone.id } ? Self.leftOver : refusal.message)
                return
            }
            code = .showing(
                try PairingCode.forThisMac(
                    credential: credential, actor: actor, daemon: daemon, relay: reach,
                    name: Host.current().localizedName))
        } catch let error as DaemonError {
            code = .failed(Self.message(error))
        } catch {
            code = .failed("Couldn't make a code: \(error)")
        }
    }

    /// Leaves the credential live: the code may have been scanned.
    func hideCode() { if case .showing = code { code = .hidden } }

    /// The code shown was not used: revoke its credential and drop its row, as Unpair does.
    func cancelCode(daemon: URL, bearer: String?) async {
        guard case .showing(let shown) = code, let phone = phones.list.first(where: { $0.id == shown.credentialID })
        else { return }
        await unpair(phone, daemon: daemon, bearer: bearer)
        if phones.list.contains(where: { $0.id == phone.id }) {
            // The revoke failed: the row stays with its error, and the code closes so it isn't scanned meanwhile.
            code = .hidden
        }
    }

    /// Revokes the phone's credential, then forgets it. A failed revoke keeps the phone listed, so it can be tried again.
    func unpair(_ phone: PairedPhone, daemon: URL, bearer: String?) async {
        unpairErrors[phone.id] = nil
        if let refusal = phones.refusesRevoke(phone, at: daemon) {
            // A made-up row was never issued: forget it. Another daemon's row stays, with why.
            if refusal == .madeUp { forget(phone) } else { unpairErrors[phone.id] = refusal.message }
            return
        }
        unpairing.insert(phone.id)
        defer { unpairing.remove(phone.id) }
        do {
            try await DaemonHTTP(baseURL: daemon, timeout: 5, bearer: bearer).revokeAppCredential(id: phone.id)
            forget(phone)
        } catch {
            unpairErrors[phone.id] = Self.message(error)
        }
    }

    private func forget(_ phone: PairedPhone) {
        phones.remove(id: phone.id)
        save()
        if !phones.isMadeUp { RelaySecrets.forget(phone.id) }
        if case .showing(let shown) = code, shown.credentialID == phone.id { code = .hidden }
    }

    private func save() {
        guard !phones.isMadeUp else { return }
        defaults.set(phones.data, forKey: Self.key)
    }

    /// The take-back failed: the row stays, with its error, for Unpair.
    static let leftOver = "No phone could use the code, and taking it back failed. Unpair it below."

    static func elsewhere(_ host: String) -> String {
        "The daemon runs at \(host), not on this Mac. A phone pairs with the Mac that runs the daemon."
    }

    static func message(_ error: DaemonError) -> String {
        switch error {
        case .http(404, _): "This daemon is too old to pair a phone. Update OpenRig, then try again."
        case .http(401, _), .http(403, _): "The daemon refused. Check the operator token in Connection."
        default: error.userMessage
        }
    }
}

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
    /// Unpair's error, by phone.
    private(set) var unpairErrors: [PairedPhone.ID: String] = [:]
    private(set) var unpairing: Set<PairedPhone.ID> = []

    private let defaults: UserDefaults
    private static let key = "pairedPhones"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        phones = PairedPhones(data: defaults.data(forKey: Self.key))
    }

    /// Issues a credential that answers as `actor` and shows its code. The phone is recorded at once: the credential
    /// exists from here on, and the record is the only way to revoke it.
    func pair(daemon: URL, bearer: String?, actor: String) async {
        code = .issuing
        let host = daemon.host() ?? daemon.absoluteString
        guard PairingCode.Reach.Kind.loopback.accepts(host) else {
            code = .failed(Self.elsewhere(host))
            return
        }
        do {
            let credential = try await DaemonHTTP(baseURL: daemon, timeout: 5, bearer: bearer)
                .issueAppCredential(for: [actor])
            phones.add(PairedPhone(id: credential.id, name: "Phone", actor: actor, paired: .now))
            save()
            code = .showing(try PairingCode.forThisMac(credential: credential, actor: actor, daemon: daemon))
        } catch let error as DaemonError {
            code = .failed(Self.message(error))
        } catch {
            code = .failed("Couldn't make a code: \(error)")
        }
    }

    func hideCode() { code = .hidden }

    /// Revokes the phone's credential, then forgets it. A failed revoke keeps the phone listed, so it can be tried again.
    func unpair(_ phone: PairedPhone, daemon: URL, bearer: String?) async {
        unpairing.insert(phone.id)
        defer { unpairing.remove(phone.id) }
        unpairErrors[phone.id] = nil
        do {
            try await DaemonHTTP(baseURL: daemon, timeout: 5, bearer: bearer).revokeAppCredential(id: phone.id)
            phones.remove(id: phone.id)
            save()
            if case .showing(let shown) = code, shown.credentialID == phone.id { code = .hidden }
        } catch {
            unpairErrors[phone.id] = Self.message(error)
        }
    }

    private func save() { defaults.set(phones.data, forKey: Self.key) }

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

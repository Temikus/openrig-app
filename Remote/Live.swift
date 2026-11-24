import Foundation
import RigClient
import RigModel

extension RemoteSession {
    /// The Keychain and the real network. Debug builds apply `OPENRIG_DEBUG_STATE`.
    static func live() -> RemoteSession {
        let standard = RemoteConnector.standardClient()
        #if DEBUG
            let relayHost = DebugHooks.relayHost
        #endif
        let reach: @Sendable (RemoteEndpoint) -> RemoteEndpoint = { endpoint in
            var endpoint = endpoint
            #if DEBUG
                if endpoint.kind == .lan, let relayHost { endpoint.host = relayHost }
            #endif
            return endpoint
        }
        let session = RemoteSession(
            store: KeychainPairingStore(), outbox: FileAnswerOutbox.standard(),
            connector: RemoteConnector(
                client: { standard(reach($0), $1) }, localNetworkDenied: { await RigClient.localNetworkDenied($0) }),
            desk: { RelayTransport.deskClient(reach($0), $1) })
        #if DEBUG
            session.statusOverride = DebugHooks.state
        #endif
        return session
    }
}

/// The pairing flow's pushed screens. The explainer is the root.
enum PairingStep: Hashable {
    case scanner

    static var launchPath: [PairingStep] {
        #if DEBUG
            if DebugHooks.screen == "scanner" { return [.scanner] }
        #endif
        return []
    }
}

#if DEBUG
    /// Launch hooks for headless captures, like the Mac app's `OPENRIG_DEBUG_*`. Pass them to `simctl launch` with
    /// the `SIMCTL_CHILD_` prefix.
    enum DebugHooks {
        static var environment: [String: String] { ProcessInfo.processInfo.environment }

        /// `scanner` opens the scanner, `settings` the Settings tab.
        static var screen: String? { environment["OPENRIG_DEBUG_SCREEN"] }

        /// Pairs at launch through `pair(link:)`, as a scan or paste does. `simctl openurl` would stop at the
        /// system's "Open in OpenRig?" confirmation.
        static var pairLink: String? { environment["OPENRIG_DEBUG_PAIR_LINK"] }

        /// Handles a link as `onOpenURL` does: it waits for the person's confirmation.
        static var openedLink: String? { environment["OPENRIG_DEBUG_OPEN_LINK"] }

        /// Opens this ask's question screen once the list has it.
        static var openAsk: String? { environment["OPENRIG_DEBUG_OPEN_ASK"] }

        /// Sends every `lan` reach to this host instead, still through the relay: `127.0.0.1` reaches a relay a
        /// seat runs on loopback, so nothing listens on the Wi-Fi and macOS never asks about the firewall.
        static var relayHost: String? { environment["OPENRIG_DEBUG_RELAY_HOST"] }

        /// `1` opens Pair Again's confirmation at launch, for a capture.
        static var confirmPairAgain: Bool { environment["OPENRIG_DEBUG_CONFIRM_PAIR_AGAIN"] == "1" }

        /// `OPENRIG_DEBUG_UNSENT=<n>` puts n made-up unconfirmed answers in the outbox, under this pairing, so the
        /// Unpair confirmation can be seen with answers waiting.
        static func seedUnsent(for credential: String?) {
            guard let credential, let count = environment["OPENRIG_DEBUG_UNSENT"].flatMap(Int.init) else { return }
            let outbox = FileAnswerOutbox.standard()
            for n in 0..<count {
                try? outbox.add(
                    PendingAnswer(
                        id: "debugunsent\(n)", credentialID: credential, requestID: "qitem-made-up-\(n)",
                        body: Data("{}".utf8)))
            }
        }

        /// A draft for the opened ask: `reply:<text>`, or `picks:<question>=<option>,…`.
        static var draft: AppAnswerDraft? {
            guard let raw = environment["OPENRIG_DEBUG_DRAFT"] else { return nil }
            if raw.hasPrefix("reply:") { return AppAnswerDraft(reply: String(raw.dropFirst("reply:".count))) }
            guard raw.hasPrefix("picks:") else { return nil }
            let pairs = raw.dropFirst("picks:".count).split(separator: ",").map { $0.split(separator: "=") }
            return AppAnswerDraft(
                picks: Dictionary(
                    pairs.filter { $0.count == 2 }.map { (String($0[0]), String($0[1])) },
                    uniquingKeysWith: { a, _ in a }))
        }

        /// `1` sends the opened ask's draft as soon as it can. Only against a fake daemon.
        static var send: Bool { environment["OPENRIG_DEBUG_SEND"] == "1" }

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

import Foundation
import Observation
import RigClient
import RigModel

/// Runs `rig` commands for the UI and keeps each control's last outcome, shown next to that control.
/// Results reach the views through the event stream; nothing here refreshes state by hand.
@MainActor @Observable
final class ActionStore {
    enum Status: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    private(set) var cli: RigCLI?
    /// For the one write the CLI can't make: answering an ask's questions.
    var http: DaemonHTTP?
    /// Who the app acts as, for the CLI and the HTTP answer alike.
    private(set) var actor = Human.session
    private(set) var status: [String: Status] = [:] {
        // Results show next to their control, which VoiceOver may not be on; say them too.
        didSet {
            for (key, value) in status where oldValue[key] != value {
                switch value {
                case .succeeded(let message): announce(message)
                case .failed(let message): announce("Failed: \(message)", urgent: true)
                case .running: break
                }
            }
        }
    }
    /// Set while the daemon is unreachable: writes would fail, so their buttons disable.
    var offline = false
    /// Text typed into composers and forms, by "<action key>|<field>". It outlives the popover, panel or tile that
    /// showed it and goes when that action succeeds.
    var drafts: [String: String] = [:]
    /// Picks on a row's questions, by the For You panel's key; they go with the drafts.
    var answers = AnswerDrafts()

    func clearDrafts(for key: String) {
        drafts = drafts.filter { !$0.key.hasPrefix(key + "|") }
        answers.clear(key)
    }

    init(cli: RigCLI? = nil) {
        self.cli = cli
    }

    /// Swaps in a CLI built from Settings, keeping who the app acts as.
    func use(_ cli: RigCLI?) {
        self.cli = cli
        self.cli?.actor = actor
    }

    /// Stamps later writes with `session` as the actor.
    func act(as session: String) {
        actor = session
        cli?.actor = session
    }

    /// Records one answer on an ask through the daemon's HTTP API, under `key` like `perform`.
    @discardableResult
    func answer(_ answer: AskAnswer, on id: QItem.ID, key: String, success: String) async -> Bool {
        if offline {
            status[key] = .failed("The daemon isn't running. Start it from the sidebar, then try again.")
            return false
        }
        guard let http else {
            status[key] = .failed("Not connected to the daemon yet.")
            return false
        }
        // A result stays until the next action starts, so nobody misses it by looking away (no timeout).
        status = status.filter { if case .succeeded = $0.value { false } else { true } }
        status[key] = .running
        do {
            try await http.answer(qitem: id, answer, as: actor)
            status[key] = .succeeded(success)
            return true
        } catch {
            status[key] = .failed(error.userMessage)
            return false
        }
    }

    func isRunning(_ key: String) -> Bool { status[key] == .running }

    /// Runs `action`, recording the outcome under `key` (one key per control). Returns true on success.
    @discardableResult
    func perform(_ action: RigAction, key: String, success: String = "Done", allowOffline: Bool = false) async -> Bool {
        if offline && !allowOffline {
            status[key] = .failed("The daemon isn't running. Start it from the sidebar, then try again.")
            return false
        }
        guard let cli else {
            status[key] = .failed("rig not found. Pick it in Settings › Connection.")
            return false
        }
        status = status.filter { if case .succeeded = $0.value { false } else { true } }
        status[key] = .running
        do {
            let result = try await cli.run(action)
            if result.succeeded {
                status[key] = .succeeded(success)
                return true
            }
            // `rig send` exits 1 when it can't confirm delivery: the keys may still have landed.
            // A refusal also exits 1, so trust only the JSON's own "sent" flag.
            switch action {
            case .send, .answerPrompt:
                if result.status == 1, Self.reportsSent(result) {
                    status[key] = .succeeded("\(success), not confirmed")
                    return true
                }
            default: break
            }
            status[key] = .failed(Self.message(from: result))
        } catch {
            status[key] = .failed(error.localizedDescription)
        }
        return false
    }

    func clear(_ key: String) { status[key] = nil }

    static func reportsSent(_ result: CLIResult) -> Bool {
        struct Envelope: Decodable {
            var ok: Bool?
            var sent: Bool?
        }
        guard let data = result.stdout.data(using: .utf8),
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return false }
        return env.sent == true || (env.sent == nil && env.ok == true)
    }

    /// The CLI's own explanation: its JSON `error`, else stderr, else stdout.
    static func message(from result: CLIResult) -> String {
        struct Envelope: Decodable {
            var error: String?
            var message: String?
        }
        for text in [result.stdout, result.stderr] {
            if let data = text.data(using: .utf8), let env = try? JSONDecoder().decode(Envelope.self, from: data),
                let message = env.error ?? env.message
            {
                return message
            }
        }
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        return text.isEmpty ? "rig exited with status \(result.status)" : String(text.prefix(400))
    }
}

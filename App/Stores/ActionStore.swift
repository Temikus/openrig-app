import Foundation
import Observation
import RigClient

/// Runs `rig` commands for the UI and keeps each control's last outcome, shown next to that control.
/// Results reach the views through the event stream; nothing here refreshes state by hand.
@MainActor @Observable
final class ActionStore {
    enum Status: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    let cli: RigCLI?
    private(set) var status: [String: Status] = [:]

    init(cli: RigCLI? = RigCLI.locate(actor: "operator-human@kernel")) {
        self.cli = cli
    }

    func isRunning(_ key: String) -> Bool { status[key] == .running }

    /// Runs `action`, recording the outcome under `key` (one key per control). Returns true on success.
    @discardableResult
    func perform(_ action: RigAction, key: String, success: String = "Done") async -> Bool {
        guard let cli else {
            status[key] = .failed("rig CLI not found in /opt/homebrew/bin or /usr/local/bin.")
            return false
        }
        status[key] = .running
        do {
            let result = try await cli.run(action)
            if result.succeeded {
                status[key] = .succeeded(success)
                clearLater(key)
                return true
            }
            // `rig send` exits 1 when it can't confirm delivery; the text may still have landed.
            if case .send = action, result.status == 1 {
                status[key] = .succeeded("Sent, delivery not confirmed")
                clearLater(key)
                return true
            }
            status[key] = .failed(Self.message(from: result))
        } catch {
            status[key] = .failed(error.localizedDescription)
        }
        return false
    }

    func clear(_ key: String) { status[key] = nil }

    private func clearLater(_ key: String) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .succeeded = status[key] { status[key] = nil }
        }
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

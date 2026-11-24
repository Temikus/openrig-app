import Foundation
import RigModel

public enum Priority: String, CaseIterable, Sendable {
    case routine, urgent, critical
}

/// `--closure-reason` values a human picks when closing. `handed_off_to` is set by `rig queue handoff`.
public enum CloseReason: String, CaseIterable, Sendable {
    case noFollowOn = "no-follow-on"
    case denied, canceled, superseded, escalation

    /// Superseded needs the replacing qitem; escalation needs the seat it went to.
    public var needsTarget: Bool { self == .superseded || self == .escalation }
}

/// One user action as a `rig` command line. Writes go through the CLI, not the HTTP API: it is the
/// documented contract and carries the guards and identity stamping.
public enum RigAction: Sendable, Equatable {
    case send(session: String, text: String)
    case create(destination: String, summary: String, body: String, priority: Priority)
    case handoff(id: String, to: String, summary: String, body: String?)
    /// `note` is the decision owed, kept as the transition note.
    case block(id: String, on: String, wakeAfter: String?, note: String?)
    case close(id: String, reason: CloseReason, target: String?, resolution: String?)
    case note(id: String, text: String)
    case newDeadline(id: String, at: Date)
    /// Types `keys` into a permission prompt. `--dangerously-interact` is the only sanctioned way in;
    /// the reason lands in the daemon's audit log.
    case answerPrompt(session: String, keys: String, reason: String)
    /// Unparks a row blocked on a human, recording the decision.
    case resolve(id: String, decision: String)
    /// Records that a prompt the daemon still holds is gone. Declines send no hook,
    /// and `rig send` refuses until this is done.
    case clearAttention(session: String, reason: String)
    case startDaemon
    /// Brings a stopped rig back, resuming each seat's conversation where its harness allows. `--yes` because the
    /// app has already asked; without a terminal the CLI would otherwise exit without acting.
    case rigUp(rig: String)
    /// Stops every seat. The CLI snapshots first anyway; `--snapshot` makes that explicit.
    case rigDown(rig: String)
    /// Hides a stopped rig from the rig list and keeps all its data; `rig unarchive` brings it back. No `--force`:
    /// the app archives only stopped rigs.
    case rigArchive(rig: String)
    /// Removes a stopped rig's record, so Start Rig can't bring it back. `--yes` because the app has already asked.
    case rigDelete(rig: String)
    /// Launches one seat of a running rig, resuming it. Seats already running are left alone.
    case launchSeat(rig: String, logicalId: String)
    /// Starts one seat with a blank conversation. Sibling seats stay attached.
    case freshSeat(session: String, reason: String)

    /// Arguments after `rig`. Passed to exec directly; no shell sees them.
    public var arguments: [String] {
        var args: [String]
        switch self {
        case .send(let session, let text):
            args = ["send", session, text]
        case .create(let destination, let summary, _, let priority):
            args = [
                "queue", "create", "--destination", destination, "--summary", summary, "--priority", priority.rawValue,
                "--body-file", "-",
            ]
        case .handoff(let id, let to, let summary, let body):
            args = ["queue", "handoff", id, "--to", to, "--summary", summary]
            if body != nil { args += ["--body-file", "-"] }
        case .block(let id, let on, let wakeAfter, let note):
            args = ["queue", "block", id, "--on", on]
            if let wakeAfter { args += ["--wake-after", wakeAfter] }
            if let note { args += ["--note", note] }
        case .close(let id, let reason, let target, let resolution):
            args = ["queue", "update", id, "--state", "done", "--closure-reason", reason.rawValue]
            if let target { args += ["--closure-target", target] }
            if let resolution { args += ["--resolution", resolution] }
        case .note(let id, let text):
            args = ["queue", "update", id, "--note", text]
        case .newDeadline(let id, let at):
            args = ["queue", "update", id, "--closure-required-at", at.formatted(.iso8601)]
        case .answerPrompt(let session, let keys, let reason):
            args = ["send", session, keys, "--dangerously-interact", "--reason", reason]
        case .resolve(let id, let decision):
            args = ["queue", "resolve", id, "--decision", decision]
        case .clearAttention(let session, let reason):
            args = ["seat", "clear-attention", session, "--reason", reason]
        case .startDaemon:
            return ["daemon", "start"]
        case .rigUp(let rig):
            args = ["up", rig, "--existing", "--yes"]
        case .rigDown(let rig):
            args = ["down", rig, "--snapshot", "--yes"]
        case .rigArchive(let rig):
            args = ["archive", rig]
        case .rigDelete(let rig):
            args = ["down", rig, "--delete", "--yes"]
        case .launchSeat(let rig, let logicalId):
            args = ["launch", rig, logicalId]
        case .freshSeat(let session, let reason):
            args = ["seat", "launch", session, "--fresh", "--reason", reason]
        }
        return args + ["--json"]
    }

    /// Text fed on stdin (bodies), so long or odd text never sits in argv.
    public var stdin: String? {
        switch self {
        case .create(_, let summary, let body, _): body.isEmpty ? summary : body
        case .handoff(_, _, _, let body): body
        default: nil
        }
    }

    /// The command as the user would type it, for showing under a button and in errors.
    public var displayCommand: String {
        (["rig"] + arguments).map(shellQuote).joined(separator: " ")
    }

    /// The command without the flags only the app needs (`--json` for parsing, `--yes` for confirming in its own UI).
    public var userCommand: String {
        (["rig"] + arguments.filter { $0 != "--json" && $0 != "--yes" }).map(shellQuote).joined(separator: " ")
    }
}

func shellQuote(_ s: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Running the CLI needs Process, which iOS lacks. The actions above stay: Answer builds them on every platform.
#if os(macOS)
    public struct CLIResult: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var succeeded: Bool { status == 0 }
    }

    /// Runs the `rig` CLI as the app's seat.
    public struct RigCLI: Sendable {
        public var executable: URL
        /// Session stamped as the actor on every write, via `OPENRIG_SESSION_NAME`.
        public var actor: String
        /// The daemon the app reads from, so the CLI writes to the same one. Nil lets the CLI find its own.
        public var daemonURL: URL?
        /// Operator bearer for gated writes; the CLI reads it from `OPENRIG_AUTH_BEARER_TOKEN`.
        public var bearer: String?
        /// Prepended to PATH: the folder of a node the person picked (nvm, asdf, mise).
        public var extraPath: String?
        /// The person's shell PATH (`ShellPath`), after `extraPath`, so `rig` finds the node their terminal uses.
        public var shellPath: [String]

        public init(
            executable: URL, actor: String, daemonURL: URL? = nil, bearer: String? = nil, extraPath: String? = nil,
            shellPath: [String] = []
        ) {
            self.executable = executable
            self.actor = actor
            self.daemonURL = daemonURL
            self.bearer = bearer
            self.extraPath = extraPath
            self.shellPath = shellPath
        }

        /// The usual install places, searched after the shell's PATH.
        public static let searchPaths = ["/opt/homebrew/bin/rig", "/usr/local/bin/rig"]

        /// The first `rig` in `searchPaths`.
        public static func locate(searchPaths: [String] = searchPaths, actor: String = Human.session) -> RigCLI? {
            ToolLocator.resolve(override: nil, searchPaths: searchPaths).map {
                RigCLI(executable: $0.url, actor: actor)
            }
        }

        /// The `rig` the person's shell finds, else one in the usual install places, run with the shell's PATH.
        public static func find(actor: String = Human.session) async -> RigCLI? {
            let shellPath = await ShellPath.load()
            let paths = ToolLocator.searchPaths(for: "rig", shellPath: shellPath, fallback: searchPaths)
            var cli = locate(searchPaths: paths, actor: actor)
            cli?.shellPath = shellPath
            return cli
        }

        static func environment(
            base: [String: String], actor: String, daemonURL: URL? = nil, bearer: String? = nil,
            extraPath: String? = nil,
            shellPath: [String] = []
        ) -> [String: String] {
            var env = base
            env["OPENRIG_SESSION_NAME"] = actor
            if let daemonURL { env["OPENRIG_URL"] = daemonURL.absoluteString }
            if let bearer, !bearer.isEmpty { env["OPENRIG_AUTH_BEARER_TOKEN"] = bearer }
            // rig is a Node script: its `#!/usr/bin/env node` needs node on PATH.
            let prefix = (extraPath.map { [$0] } ?? []) + shellPath + ["/opt/homebrew/bin", "/usr/local/bin"]
            env["PATH"] = (prefix + [base["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            env["NO_COLOR"] = "1"
            return env
        }

        public func run(_ action: RigAction) async throws -> CLIResult {
            try await run(arguments: action.arguments, stdin: action.stdin)
        }

        public func run(arguments: [String], stdin: String? = nil) async throws -> CLIResult {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = Self.environment(
                base: ProcessInfo.processInfo.environment, actor: actor, daemonURL: daemonURL, bearer: bearer,
                extraPath: extraPath, shellPath: shellPath)
            let input = Pipe()
            let out = Pipe()
            let err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            // Set before launch, so an exit that comes before anyone waits is still seen. `waitUntilExit` from a
            // detached task has hung after the child had already exited.
            let exited = AsyncStream<Void> { done in
                process.terminationHandler = { _ in
                    done.yield()
                    done.finish()
                }
            }
            try process.run()

            input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
            try input.fileHandleForWriting.close()

            // Drain both pipes concurrently so neither can fill and stall the child.
            async let stdoutData = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (o, e) = await (stdoutData, stderrData)
            // Detached, so cancellation can't end the wait early: reading the status of an unreaped child throws.
            await Task.detached { for await _ in exited { break } }.value
            return CLIResult(
                status: process.terminationStatus,
                stdout: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
#endif

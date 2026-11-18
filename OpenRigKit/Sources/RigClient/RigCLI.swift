import Foundation

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
    case block(id: String, on: String, wakeAfter: String?, summary: String?)
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
        case .block(let id, let on, let wakeAfter, let summary):
            args = ["queue", "block", id, "--on", on]
            if let wakeAfter { args += ["--wake-after", wakeAfter] }
            if let summary { args += ["--summary", summary] }
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
}

func shellQuote(_ s: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

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

    public init(executable: URL, actor: String) {
        self.executable = executable
        self.actor = actor
    }

    public static let searchPaths = ["/opt/homebrew/bin/rig", "/usr/local/bin/rig"]

    /// GUI apps don't inherit the shell's PATH, so look in the usual install places.
    public static func locate(searchPaths: [String] = searchPaths, actor: String = "operator-human@kernel") -> RigCLI? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { RigCLI(executable: URL(filePath: $0), actor: actor) }
    }

    static func environment(base: [String: String], actor: String) -> [String: String] {
        var env = base
        env["OPENRIG_SESSION_NAME"] = actor
        // rig is a Node script: its `#!/usr/bin/env node` needs node on PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (base["PATH"] ?? "/usr/bin:/bin")
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
        process.environment = Self.environment(base: ProcessInfo.processInfo.environment, actor: actor)
        let input = Pipe()
        let out = Pipe()
        let err = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = err
        try process.run()

        input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
        try input.fileHandleForWriting.close()

        // Drain both pipes concurrently so neither can fill and stall the child.
        async let stdoutData = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderrData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let (o, e) = await (stdoutData, stderrData)
        await Task.detached { process.waitUntilExit() }.value
        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

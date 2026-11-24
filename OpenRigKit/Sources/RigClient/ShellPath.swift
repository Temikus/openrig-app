import Foundation
import Synchronization

/// The PATH the person's terminal has. An app opened from the Dock gets launchd's short PATH, so `rig` and `node`
/// installed under nvm, asdf, mise or Volta aren't on it. This asks the login shell once, as VS Code does.
public enum ShellPath {
    static let marker = "__OPENRIG_PATH__="

    /// The folders on the PATH line printed after `marker`, in order, without blanks or repeats. Startup files can
    /// print their own text before it, so only the last marked line counts, and only once its newline has arrived.
    /// Nil when no complete line is marked.
    static func parse(_ output: String) -> [String]? {
        guard let end = output.lastIndex(where: \.isNewline),
            let line = output[..<end].split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) })
        else { return nil }
        var seen = Set<String>()
        return line.dropFirst(marker.count).split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Output gathered as it arrives, so nothing blocks on the pipe closing.
    private final class Output: Sendable {
        let state = Mutex<(data: Data, closed: Bool)>((Data(), false))
        var text: String { String(decoding: state.withLock { $0.data }, as: UTF8.self) }
        var closed: Bool { state.withLock { $0.closed } }
    }

    /// Runs `shell -ilc` and reads its PATH. Interactive as well as login: nvm usually loads from `.zshrc`, which a
    /// login-only zsh skips. Nil when the shell fails, prints no PATH or hasn't finished within `timeout`.
    ///
    /// The deadline ends the wait itself. Interactive zsh ignores SIGTERM, so a late shell is killed; and a
    /// background job started by a startup file can hold stdout open long after the shell exits, so the PATH counts
    /// once the shell has exited and printed it, without waiting for the pipe to close.
    static func read(shell: String, timeout: Duration = .seconds(5)) async -> [String]? {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        // Lets startup files skip slow work, like VS Code's VSCODE_RESOLVING_ENVIRONMENT.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["OPENRIG_RESOLVING_ENVIRONMENT": "1"]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let output = Output()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            output.state.withLock { state in
                if chunk.isEmpty { state.closed = true } else { state.data.append(chunk) }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        defer { out.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return nil }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning, output.closed || parse(output.text) != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else {
            // `Process` starts the shell in its own process group, so a startup command it waits on (a curl with
            // no timeout, say) dies with it.
            let pid = process.processIdentifier
            kill(pid, SIGKILL)
            _ = kill(-pid, SIGKILL)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return parse(output.text)
    }

    /// `$SHELL`, else the account's shell from the user database, else zsh (the macOS default).
    static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    private static let cached = Mutex<Task<[String], Never>?>(nil)

    /// The shell's PATH folders, asked for once per launch. Empty when the shell can't tell, which leaves the
    /// usual install places as the only ones searched.
    public static func load() async -> [String] {
        let task = cached.withLock { task in
            if let task { return task }
            let shell = loginShell()
            let new = Task.detached { await read(shell: shell) ?? [] }
            task = new
            return new
        }
        return await task.value
    }
}

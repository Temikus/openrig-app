import Foundation
import Synchronization

/// The PATH the person's terminal has. An app opened from the Dock gets launchd's short PATH, so `rig` and `node`
/// installed under nvm, asdf, mise or Volta aren't on it. This asks the login shell once, as VS Code does.
public enum ShellPath {
    static let marker = "__OPENRIG_PATH__="

    /// The folders on the PATH line printed after `marker`, in order, without blanks or repeats. Startup files can
    /// print their own text before it, so only the last marked line counts. Nil when no line is marked.
    static func parse(_ output: String) -> [String]? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        var seen = Set<String>()
        return line.dropFirst(marker.count).split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Runs `shell -ilc` and reads its PATH. Interactive as well as login: nvm usually loads from `.zshrc`, which a
    /// login-only zsh skips. Nil when the shell fails, prints no PATH or takes longer than `timeout`.
    static func read(shell: String, timeout: Duration = .seconds(5)) async -> [String]? {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        watchdog.cancel()
        while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
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

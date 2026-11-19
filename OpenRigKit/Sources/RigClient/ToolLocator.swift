import Foundation

/// Where a command-line tool was found, and whether the person picked it.
public struct ToolLocation: Sendable, Equatable {
    public var url: URL
    public var chosen: Bool

    public init(url: URL, chosen: Bool) {
        self.url = url
        self.chosen = chosen
    }
}

/// Finds `rig`, `tmux` and `node` for an app opened from the Dock, which doesn't get the shell's PATH.
public enum ToolLocator {
    /// The person's pick when there is one, else the first executable in `searchPaths`. A pick that is no longer
    /// executable gives nil rather than another install, so Settings can say the chosen file is missing.
    public static func resolve(
        override: URL?, searchPaths: [String], fileManager: FileManager = .default
    ) -> ToolLocation? {
        if let override {
            return fileManager.isExecutableFile(atPath: override.path) ? ToolLocation(url: override, chosen: true) : nil
        }
        return searchPaths.first { fileManager.isExecutableFile(atPath: $0) }
            .map { ToolLocation(url: URL(filePath: $0), chosen: false) }
    }

    /// The tool's version: the first word of its output that starts with a digit or "v<digit>" ("tmux 3.5a" gives
    /// "3.5a", "0.7.11 (6c8a6963)" gives "0.7.11"). tmux takes `-V`. Nil when it doesn't run or answer in `timeout`.
    public static func version(
        of executable: URL, flag: String = "--version", timeout: Duration = .seconds(2)
    ) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "NO_COLOR": "1"]
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
        // Output closed, so the child is exiting; poll rather than block a cooperative thread on waitUntilExit.
        while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        guard process.terminationStatus == 0 else { return nil }
        let words = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        return words.first { $0.wholeMatch(of: /v?\d[\w.\-]*/) != nil }.map(String.init)
    }
}

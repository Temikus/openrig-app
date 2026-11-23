import Foundation

public enum TmuxError: Error, Equatable, Sendable {
    case notInstalled
    case failed(status: Int32, stderr: String)
}

/// Runs tmux against OpenRig's server socket. Every call is one short-lived `tmux` process;
/// nothing here keeps a client attached (see `AttachSession` for that).
public struct Tmux: Sendable {
    public var executable: URL
    public var socketPath: String

    public init(executable: URL, socketPath: String) {
        self.executable = executable
        self.socketPath = socketPath
    }

    /// GUI apps don't inherit the shell's PATH, so look in the usual install places.
    public static let searchPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// The tmux OpenRig uses: its socket comes from `$OPENRIG_HOME/tmux-server.json`,
    /// falling back to tmux's own default socket for this user.
    /// `executable` is the person's pick from Settings; when given, the search paths aren't tried.
    public static func locate(
        openRigHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".openrig"),
        executable: URL? = nil,
        fileManager: FileManager = .default
    ) -> Tmux? {
        let candidates = executable.map { [$0.path] } ?? searchPaths
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else { return nil }
        struct ServerFile: Decodable { var socketPath: String? }
        let configured = (try? Data(contentsOf: openRigHome.appending(path: "tmux-server.json")))
            .flatMap { try? JSONDecoder().decode(ServerFile.self, from: $0) }?.socketPath
        let socket = configured ?? "/private/tmp/tmux-\(getuid())/default"
        return Tmux(executable: URL(filePath: path), socketPath: socket)
    }

    /// Arguments that select the socket; prepend to any tmux command line.
    public var socketArgs: [String] { ["-S", socketPath] }

    @discardableResult
    public func run(_ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = socketArgs + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            // Read both pipes before waiting, or a full pipe buffer deadlocks the child.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: TmuxError.notInstalled)
                    return
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: stdout, as: UTF8.self))
                } else {
                    continuation.resume(
                        throwing: TmuxError.failed(
                            status: process.terminationStatus,
                            stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(
                                in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    /// tty names of the clients attached to a session.
    public func clients(session: String) async throws -> [String] {
        let output = try await run(["list-clients", "-t", "=\(session)", "-F", "#{client_tty}"])
        return output.split(separator: "\n").map(String.init)
    }

    /// Asks tmux to redraw the client started as process `pid` (one of this app's attach clients).
    public func redraw(clientPID pid: Int32) async {
        guard let output = try? await run(["list-clients", "-F", "#{client_pid} #{client_tty}"]),
            let tty = output.split(separator: "\n").first(where: { $0.hasPrefix("\(pid) ") })?.split(separator: " ")
                .last
        else { return }
        _ = try? await run(["refresh-client", "-t", String(tty)])
    }

    /// The tty of the client started as process `pid` (one of this app's attach clients).
    public func clientTTY(pid: Int32) async -> String? {
        guard let output = try? await run(["list-clients", "-F", "#{client_pid} #{client_tty}"]) else { return nil }
        return output.split(separator: "\n").first { $0.hasPrefix("\(pid) ") }?.split(separator: " ").last
            .map(String.init)
    }

    /// Pans a client shorter than its pane down by `rows` (see `PaneSnapshot.panOffset`). `-c` first returns it to
    /// following the cursor, which for a hidden cursor is the top, so repeated calls don't add up.
    public func pan(tty: String, down rows: Int) async {
        _ = try? await run(["refresh-client", "-t", tty, "-c"])
        if rows > 0 { _ = try? await run(["refresh-client", "-t", tty, "-D", String(rows)]) }
    }

    /// Arguments that attach a client to one seat's session. `ignore-size` keeps this client from
    /// resizing a pane other terminals are showing (PLAN.md risk 4); the view scales to the pane instead.
    /// `-u`: the client's terminal is SwiftTerm, which reads UTF-8. Without it, a client with no UTF-8 locale
    /// (an app opened from Finder has none) sends `_` for every non-ASCII character.
    public func attachArgs(session: String) -> [String] {
        ["-u"] + socketArgs + ["attach-session", "-f", "ignore-size", "-t", "=\(session)"]
    }
}

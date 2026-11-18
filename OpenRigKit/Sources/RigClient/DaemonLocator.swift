import Foundation

/// Where the daemon is, and how we found out.
public struct DaemonEndpoint: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case environment
        case stateFile(pid: Int)
        case fallback
    }

    public var baseURL: URL
    public var source: Source

    public init(baseURL: URL, source: Source) {
        self.baseURL = baseURL
        self.source = source
    }
}

/// Finds the daemon the same way the `rig` CLI does (`dist/client.js`, rig 0.7.11):
/// `OPENRIG_URL`, then `$OPENRIG_HOME/daemon.json` (default `~/.openrig`), then 127.0.0.1:7433.
/// A stale pid in daemon.json still wins; the request decides reachability, as in the CLI.
public struct DaemonLocator: Sendable {
    public static let defaultURL = URL(string: "http://127.0.0.1:7433")!

    var environment: [String: String]
    var homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public var openRigHome: URL {
        if let configured = environment["OPENRIG_HOME"], !configured.isEmpty {
            return URL(filePath: configured, directoryHint: .isDirectory)
        }
        return homeDirectory.appending(path: ".openrig", directoryHint: .isDirectory)
    }

    public var stateFile: URL { openRigHome.appending(path: "daemon.json") }

    public func locate() -> DaemonEndpoint {
        if let raw = environment["OPENRIG_URL"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
            let url = URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw), url.host() != nil
        {
            return DaemonEndpoint(baseURL: url, source: .environment)
        }
        if let state = readStateFile() {
            return state
        }
        return DaemonEndpoint(baseURL: Self.defaultURL, source: .fallback)
    }

    private struct StateFile: Decodable {
        var pid: Int
        var port: Int
        var host: String?
    }

    private func readStateFile() -> DaemonEndpoint? {
        guard let data = try? Data(contentsOf: stateFile),
            let state = try? JSONDecoder().decode(StateFile.self, from: data),
            state.pid > 0, (1...65535).contains(state.port)
        else { return nil }
        var host = (state.host ?? "127.0.0.1").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        guard let url = URL(string: "http://\(host):\(state.port)") else { return nil }
        return DaemonEndpoint(baseURL: url, source: .stateFile(pid: state.pid))
    }
}

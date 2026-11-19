import Foundation
import Testing

@testable import RigClient

@Suite struct DaemonLocatorTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "openrig-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".openrig"), withIntermediateDirectories: true)
    }

    func writeState(_ json: String, in dir: URL? = nil) throws {
        let dir = dir ?? home.appending(path: ".openrig")
        try Data(json.utf8).write(to: dir.appending(path: "daemon.json"))
    }

    @Test func readsStateFile() throws {
        try writeState(#"{"pid":81983,"port":7500,"host":"127.0.0.1","db":"/x/openrig.sqlite"}"#)
        let endpoint = DaemonLocator(environment: [:], homeDirectory: home).locate()
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:7500")
        #expect(endpoint.source == .stateFile(pid: 81983))
    }

    @Test func missingHostMeansLoopback() throws {
        try writeState(#"{"pid":1,"port":7433}"#)
        #expect(
            DaemonLocator(environment: [:], homeDirectory: home).locate().baseURL.absoluteString
                == "http://127.0.0.1:7433")
    }

    @Test func bracketsIPv6Hosts() throws {
        try writeState(#"{"pid":1,"port":7433,"host":"::1"}"#)
        #expect(
            DaemonLocator(environment: [:], homeDirectory: home).locate().baseURL.absoluteString == "http://[::1]:7433")
    }

    @Test(arguments: [
        #"{"pid":0,"port":7433}"#,
        #"{"pid":1,"port":70000}"#,
        #"{"pid":1,"port":7433,"host":"  "}"#,
        #"not json"#,
    ])
    func invalidStateFileFallsBack(json: String) throws {
        try writeState(json)
        #expect(DaemonLocator(environment: [:], homeDirectory: home).locate().source == .fallback)
    }

    @Test func noStateFileFallsBack() {
        let endpoint = DaemonLocator(environment: [:], homeDirectory: home).locate()
        #expect(endpoint == DaemonEndpoint(baseURL: DaemonLocator.defaultURL, source: .fallback))
    }

    @Test func openRigURLWins() throws {
        try writeState(#"{"pid":1,"port":7500}"#)
        let env = ["OPENRIG_URL": "http://10.0.0.5:9000/"]
        let endpoint = DaemonLocator(environment: env, homeDirectory: home).locate()
        #expect(endpoint.baseURL.absoluteString == "http://10.0.0.5:9000")
        #expect(endpoint.source == .environment)
    }

    @Test func overrideBeatsEnvironmentAndStateFile() throws {
        try writeState(#"{"pid":1,"port":7500}"#)
        let locator = DaemonLocator(
            environment: ["OPENRIG_URL": "http://10.0.0.5:9000"], homeDirectory: home,
            override: URL(string: "http://10.0.4.12:7433/"))
        let endpoint = locator.locate()
        #expect(endpoint.baseURL.absoluteString == "http://10.0.4.12:7433")
        #expect(endpoint.source == .custom)
    }

    @Test func openRigHomeMovesTheStateFile() throws {
        let custom = home.appending(path: "custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try writeState(#"{"pid":2,"port":7600}"#, in: custom)
        let endpoint = DaemonLocator(environment: ["OPENRIG_HOME": custom.path], homeDirectory: home).locate()
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:7600")
    }
}

@Suite struct DaemonHTTPErrors {
    @Test func closedPortIsUnreachable() async throws {
        // Port 9 (discard) is closed on macOS by default.
        let client = DaemonHTTP(baseURL: URL(string: "http://127.0.0.1:9")!, timeout: 2)
        await #expect(throws: DaemonError.self) { try await client.health() }
        do {
            _ = try await client.health()
        } catch {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
        }
    }
}

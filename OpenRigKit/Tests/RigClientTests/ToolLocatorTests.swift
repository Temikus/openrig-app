import Foundation
import Synchronization
import Testing

@testable import RigClient

@Suite struct ToolLocatorTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "openrig-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// An executable script that prints `output` and exits.
    func tool(_ name: String, printing output: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data("#!/bin/sh\necho '\(output)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func autoPicksTheFirstExecutable() throws {
        let rig = try tool("rig", printing: "0.7.11")
        let found = ToolLocator.resolve(override: nil, searchPaths: ["/nonexistent/rig", rig.path])
        #expect(found == ToolLocation(url: rig, chosen: false))
    }

    @Test func overrideWins() throws {
        let auto = try tool("rig", printing: "0.7.11")
        let chosen = try tool("rig-custom", printing: "0.8.0")
        let found = ToolLocator.resolve(override: chosen, searchPaths: [auto.path])
        #expect(found == ToolLocation(url: chosen, chosen: true))
    }

    @Test func missingOverrideIsNotReplacedByAuto() throws {
        // A chosen file that went away is reported, not silently swapped for another install.
        let auto = try tool("rig", printing: "0.7.11")
        let found = ToolLocator.resolve(override: dir.appending(path: "gone"), searchPaths: [auto.path])
        #expect(found == nil)
    }

    @Test func versionIsTheFirstLineOfOutput() async throws {
        let rig = try tool("rig", printing: "0.7.11")
        #expect(await ToolLocator.version(of: rig) == "0.7.11")
    }

    @Test func versionIsTheFirstVersionLikeWord() async throws {
        let rig = try tool("rig", printing: "0.7.11 (6c8a6963)")
        #expect(await ToolLocator.version(of: rig) == "0.7.11", "not the commit hash after it")
        let tmux = try tool("tmux", printing: "tmux 3.5a")
        #expect(await ToolLocator.version(of: tmux, flag: "-V") == "3.5a")
        let node = try tool("node", printing: "v22.11.0")
        #expect(await ToolLocator.version(of: node) == "v22.11.0")
    }

    @Test func versionOfAMissingToolIsNil() async {
        #expect(await ToolLocator.version(of: dir.appending(path: "nope")) == nil)
    }
}

@Suite struct DaemonHTTPBearerTests {
    @Test func bearerIsSentWithEveryRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        let client = DaemonHTTP(
            baseURL: URL(string: "http://bearer.test")!, session: URLSession(configuration: config), bearer: "s3cret")
        _ = try? await client.health()
        #expect(RecordingProtocol.lastAuthorization.withLock { $0 } == "Bearer s3cret")
    }
}

/// Records the Authorization header of the last request and answers 500, so no real network is touched.
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let lastAuthorization = Mutex<String?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bearer.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastAuthorization.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct OperatorAuthTests {
    /// The stub answers with the status named in the URL, so parallel tests don't share state.
    func client(status: Int) -> DaemonHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusProtocol.self]
        return DaemonHTTP(
            baseURL: URL(string: "http://auth.test/\(status)")!, session: URLSession(configuration: config))
    }

    @Test func aGateRefusalIsRejected() async {
        #expect(await client(status: 401).checkOperatorAuth(as: "human@host") == .rejected(status: 401))
        #expect(await client(status: 403).checkOperatorAuth(as: "human@host") == .rejected(status: 403))
    }

    /// Past the gate, the probe's made-up row is simply not found: nothing is answered.
    @Test func anythingPastTheGateIsAccepted() async {
        #expect(await client(status: 404).checkOperatorAuth(as: "human@host") == .accepted)
        #expect(await client(status: 400).checkOperatorAuth(as: "human@host") == .accepted)
    }
}

/// Answers each request to auth.test with the status in the URL's first path component.
final class StatusProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "auth.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = Int(request.url?.pathComponents.dropFirst().first ?? "") ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"qitem_not_found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

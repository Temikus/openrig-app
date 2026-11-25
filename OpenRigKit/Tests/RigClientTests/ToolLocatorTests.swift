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

@Suite struct ShellPathTests {
    @Test func readsOnlyTheMarkedLine() {
        // Startup files can print anything, including text that looks like a PATH.
        let output = """
            Welcome back!
            PATH=/decoy/bin
            __OPENRIG_PATH__=/Users/x/.nvm/versions/node/v22/bin:/opt/homebrew/bin:/usr/bin

            """
        #expect(ShellPath.parse(output) == ["/Users/x/.nvm/versions/node/v22/bin", "/opt/homebrew/bin", "/usr/bin"])
    }

    @Test func theLastMarkedLineWins() {
        let output = "__OPENRIG_PATH__=/early\n__OPENRIG_PATH__=/late/bin\n"
        #expect(ShellPath.parse(output) == ["/late/bin"])
    }

    @Test func dropsBlanksRepeatsAndRelativeFolders() {
        let output = "__OPENRIG_PATH__=/a::/b:/a:.:bin:/c\n"
        #expect(ShellPath.parse(output) == ["/a", "/b", "/c"], "a relative folder would depend on the app's cwd")
    }

    @Test func aMarkedLineCountsOnlyOnceItsNewlineArrives() {
        #expect(ShellPath.parse("__OPENRIG_PATH__=/usr/bin:/opt/home") == nil, "the rest of the PATH may follow")
        #expect(ShellPath.parse("__OPENRIG_PATH__=/usr/bin:/opt/homebrew/bin\n") == ["/usr/bin", "/opt/homebrew/bin"])
    }

    @Test func noMarkerIsNil() {
        #expect(ShellPath.parse("zsh: command not found: nvm\n") == nil)
    }

    @Test func readsAShell() async throws {
        // A stand-in shell that prints noise, then runs the command it is given with a known PATH.
        let dir = FileManager.default.temporaryDirectory.appending(path: "openrig-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shell = dir.appending(path: "sh")
        try Data("#!/bin/sh\necho 'rc noise'\nPATH=/from/shell:/usr/bin:/bin exec /bin/sh -c \"$2\"\n".utf8)
            .write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        #expect(await ShellPath.read(shell: shell.path) == ["/from/shell", "/usr/bin", "/bin"])
    }

    @Test func aFailingOrSlowShellIsNil() async throws {
        #expect(await ShellPath.read(shell: "/nonexistent/sh") == nil)
        #expect(await ShellPath.read(shell: "/usr/bin/false") == nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "openrig-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slow = dir.appending(path: "sh")
        try Data("#!/bin/sh\nexec sleep 10\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        #expect(await ShellPath.read(shell: slow.path, timeout: .milliseconds(200)) == nil)
    }

    /// A stand-in shell with `body` as its script.
    func fake(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openrig-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = dir.appending(path: "sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: sh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        return sh.path
    }

    /// Startup files can skip slow work while the app is only reading PATH.
    @Test func theShellIsToldItIsResolvingTheEnvironment() async throws {
        let sh = try fake("printf '\\n__OPENRIG_PATH__=/%s\\n' \"$OPENRIG_RESOLVING_ENVIRONMENT\"")
        #expect(await ShellPath.read(shell: sh) == ["/1"])
    }

    /// Interactive zsh ignores SIGTERM, so a shell still in its startup files at the deadline is killed, and its
    /// PATH, if it prints one later, is never used.
    @Test func aShellThatIgnoresTERMStillTimesOut() async throws {
        let sh = try fake("trap '' TERM\nsleep 6\nprintf '\\n__OPENRIG_PATH__=/late\\n'")
        let start = ContinuousClock.now
        let got = await ShellPath.read(shell: sh, timeout: .milliseconds(300))
        let took = ContinuousClock.now - start
        #expect(got == nil)
        #expect(took < .seconds(2), "took \(took)")
    }

    /// A shell stuck waiting on a startup command. At the deadline the command dies with it, rather than living on
    /// under launchd. The shell makes no process group of its own: `Process` gives it one.
    @Test func aStuckStartupCommandDiesWithTheShell() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "openrig-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appending(path: "child.pid")
        let sh = dir.appending(path: "sh")
        let script = """
            #!/usr/bin/perl
            $SIG{TERM} = 'IGNORE';
            my $child = fork();
            if ($child == 0) { exec('/bin/sleep', '30'); }
            open(my $f, '>', '\(pidFile.path)'); print $f $child; close($f);
            waitpid($child, 0);

            """
        try Data(script.utf8).write(to: sh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)

        // The deadline only has to outlast perl starting up and forking; under load that took over 500 ms.
        #expect(await ShellPath.read(shell: sh.path, timeout: .seconds(2)) == nil)
        let text = try #require(
            try? String(contentsOf: pidFile, encoding: .utf8),
            "setup: the fake shell was killed before it wrote its child's pid, so nothing was checked")
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // The killed command is reaped by launchd; until then kill(_, 0) still finds it.
        let deadline = ContinuousClock.now + .seconds(3)
        while kill(child, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let alive = kill(child, 0) == 0
        if alive { kill(child, SIGKILL) }
        #expect(!alive, "the shell's startup command outlived it")
    }

    /// A startup file that leaves a background job holding stdout: the PATH counts once the shell has exited.
    @Test func aBackgroundChildHoldingStdoutDoesNotHoldTheRead() async throws {
        let sh = try fake("sleep 6 &\nprintf '\\n__OPENRIG_PATH__=/usr/bin\\n'")
        let start = ContinuousClock.now
        let got = await ShellPath.read(shell: sh, timeout: .seconds(3))
        let took = ContinuousClock.now - start
        #expect(got == ["/usr/bin"])
        #expect(took < .seconds(2), "took \(took)")
    }

    /// The same with no PATH printed: nil at the deadline, not when the background job lets go.
    @Test func aBackgroundChildWithNoPathEndsAtTheDeadline() async throws {
        let sh = try fake("sleep 6 &\necho 'rc noise'\nexit 0")
        let start = ContinuousClock.now
        let got = await ShellPath.read(shell: sh, timeout: .milliseconds(300))
        let took = ContinuousClock.now - start
        #expect(got == nil)
        #expect(took < .seconds(2), "took \(took)")
    }

    @Test func loginShellPrefersSHELL() {
        #expect(ShellPath.loginShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]) == "/opt/homebrew/bin/fish")
        #expect(ShellPath.loginShell(environment: [:]).hasPrefix("/"), "from the user database when unset")
    }
}

@Suite struct ToolSearchOrderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "openrig-order-\(UUID().uuidString)")
        for sub in ["nvm", "brew"] {
            let folder = dir.appending(path: sub)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rig = folder.appending(path: "rig")
            try Data("#!/bin/sh\n".utf8).write(to: rig)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.path)
        }
    }

    var brew: String { dir.appending(path: "brew/rig").path }

    @Test func shellFoldersComeBeforeTheUsualPlaces() {
        let paths = ToolLocator.searchPaths(
            for: "rig", shellPath: ["/a/bin", "/opt/homebrew/bin"],
            fallback: ["/opt/homebrew/bin/rig", "/usr/local/bin/rig"])
        #expect(paths == ["/a/bin/rig", "/opt/homebrew/bin/rig", "/usr/local/bin/rig"], "in order, once each")
    }

    @Test func theShellsRigBeatsHomebrew() {
        let paths = ToolLocator.searchPaths(for: "rig", shellPath: [dir.appending(path: "nvm").path], fallback: [brew])
        #expect(ToolLocator.resolve(override: nil, searchPaths: paths)?.url.path == dir.appending(path: "nvm/rig").path)
    }

    @Test func withoutAShellPathItIsTodaysLookup() {
        let paths = ToolLocator.searchPaths(for: "rig", shellPath: [], fallback: [brew])
        #expect(paths == [brew])
    }

    @Test func aPickStillBeatsTheShell() {
        let pick = dir.appending(path: "brew/rig")
        let paths = ToolLocator.searchPaths(for: "rig", shellPath: [dir.appending(path: "nvm").path], fallback: [])
        #expect(ToolLocator.resolve(override: pick, searchPaths: paths) == ToolLocation(url: pick, chosen: true))
        #expect(ToolLocator.resolve(override: dir.appending(path: "gone"), searchPaths: paths) == nil)
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

import Foundation
import RigModel
import Synchronization
import Testing

@testable import RigClient

/// A fixture's bytes, read by path: this target doesn't link RigFixtures.
func appFixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../RigFixtures/Fixtures/\(name).json").standardized)
}

/// Each test gets its own host, so parallel tests never share a script.
struct Script {
    let host = "app-\(UUID().uuidString.lowercased()).test"
    var baseURL: URL { URL(string: "http://\(host)")! }

    init(_ replies: [ScriptedProtocol.Reply]) {
        ScriptedProtocol.scripts.withLock { $0[host] = replies }
    }

    var requests: [ScriptedProtocol.Seen] { ScriptedProtocol.seen.withLock { $0[host] ?? [] } }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        return URLSession(configuration: config)
    }

    func client(token: String = "orapp_test") -> AppClient {
        AppClient(baseURL: baseURL, token: token, actor: "human-example@external", session: session)
    }
}

/// Plays one scripted reply per request to a `*.test` host and records what was sent.
final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, Data = Data())
        /// A 200 `text/event-stream`, as the daemon sends `/events`.
        case events(Data)
        /// The connection drops before any response: the "lost response" case.
        case drop
    }
    struct Seen {
        var method: String
        var path: String
        var query: String?
        var authorization: String?
        var lastEventID: String?
        var body: Data?
    }

    static let scripts = Mutex<[String: [Reply]]>([:])
    static let seen = Mutex<[String: [Seen]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        Self.seen.withLock {
            $0[host, default: []].append(
                Seen(
                    method: request.httpMethod ?? "GET", path: request.url?.path() ?? "", query: request.url?.query(),
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    lastEventID: request.value(forHTTPHeaderField: "Last-Event-ID"), body: body))
        }
        let reply = Self.scripts.withLock { $0[host]?.isEmpty == false ? $0[host]!.removeFirst() : .status(500) }
        switch reply {
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .status(let code, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .events(let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite struct AppClientReadTests {
    @Test func readsSendTheAppTokenAndTheActor() async throws {
        let script = Script([.status(200, try appFixture("app-needs-me"))])
        let needs = try await script.client(token: "orapp_abc").needsMe()
        #expect(needs.requests.count == 2)
        let seen = try #require(script.requests.first)
        #expect(seen.authorization == "Bearer orapp_abc")
        #expect(seen.path == "/api/apps/v1/needs-me")
        #expect(seen.query == "actor=human-example@external")
    }

    @Test func requestAndResultUseTheirPaths() async throws {
        let script = Script([
            .status(200, try appFixture("app-request-unsupported")), .status(200, try appFixture("app-result")),
        ])
        let client = script.client()
        _ = try await client.request(id: "qitem-1")
        _ = try await client.result(requestID: "qitem-1")
        #expect(
            script.requests.map(\.path) == ["/api/apps/v1/requests/qitem-1", "/api/apps/v1/requests/qitem-1/result"])
    }

    @Test func unknownRequestIsRefusedWithItsCode() async throws {
        let script = Script([.status(404, try appFixture("app-error-404-request-not-found"))])
        await #expect(throws: AppError.refused(status: 404, code: "request_not_found", retrySameSubmission: nil)) {
            try await script.client().request(id: "qitem-00000000000000-0000")
        }
    }

    @Test func capabilitiesOfASupportingDaemon() async throws {
        let script = Script([.status(200, try appFixture("app-capabilities"))])
        #expect(try await script.client().capabilities().supportsAnswering)
    }

    /// An older daemon answers a plain 404: the job is unavailable there.
    @Test func plain404MeansAnUnsupportedDaemon() async {
        let script = Script([.status(404, Data(#"{"error":"not_found"}"#.utf8))])
        await #expect(throws: AppError.unsupportedDaemon) { try await script.client().capabilities() }
    }

    @Test func clientHidesItsToken() {
        let client = AppClient(baseURL: URL(string: "http://100.64.0.1:7433")!, token: "orapp_secret", actor: "a@b")
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), dumped] {
            #expect(!text.contains("orapp_secret"))
        }
    }

    @Test func unauthorizedMeansUnpaired() async {
        let script = Script([.status(401, Data(#"{"error":"unauthorized"}"#.utf8))])
        await #expect(throws: AppError.unpaired) { try await script.client().needsMe() }
    }
}

@Suite struct AppClientAnswerTests {
    func binding() throws -> AppAnswerBinding {
        let needs = try JSONDecoder().decode(AppNeedsMe.self, from: appFixture("app-needs-me"))
        return try #require(
            AppAnswerBinding.choosing("later", for: "notify", in: needs.requests[0], as: "human-example@external"))
    }

    @Test func lostResponseIsRetriedWithTheSameIDAndBinding() async throws {
        let script = Script([.drop, .status(200, try appFixture("app-receipt-returned"))])
        let receipt = try await script.client().answer(id: "a_7Qm2xVb9Lk3pR8sT", binding(), retryDelay: .zero)
        #expect(receipt.fate == .returned(reply: "qitem-20261123103104-e41b"))
        let sent = script.requests
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.method == "POST" && $0.path == "/api/apps/v1/answers/a_7Qm2xVb9Lk3pR8sT" })
        #expect(sent[0].body == sent[1].body)
        #expect(try JSONDecoder().decode(AppAnswerBinding.self, from: sent[0].body ?? Data()) == binding())
    }

    @Test func unavailableIsRetriedWithTheSameID() async throws {
        let script = Script([
            .status(503, try appFixture("app-error-503-unsaved")), .status(200, try appFixture("app-receipt-returned")),
        ])
        _ = try await script.client().answer(id: "a_7Qm2xVb9Lk3pR8sT", binding(), retryDelay: .zero)
        #expect(script.requests.map(\.path) == Array(repeating: "/api/apps/v1/answers/a_7Qm2xVb9Lk3pR8sT", count: 2))
    }

    @Test func conflictIsNeverRetried() async throws {
        let script = Script([
            .status(409, try appFixture("app-error-409-returned")),
            .status(200, try appFixture("app-receipt-returned")),
        ])
        await #expect(
            throws: AppError.refused(status: 409, code: "answer_already_returned", retrySameSubmission: false)
        ) {
            try await script.client().answer(id: "a_7Qm2xVb9Lk3pR8sT", binding(), retryDelay: .zero)
        }
        #expect(script.requests.count == 1)
    }

    @Test func givesUpAfterTheLastAttemptWithTheLastError() async throws {
        let script = Script([.drop, .drop, .drop])
        await #expect {
            try await script.client().answer(id: "a_7Qm2xVb9Lk3pR8sT", binding(), attempts: 3, retryDelay: .zero)
        } throws: { error in
            (error as? AppError)?.retrySameSubmission == true
        }
        #expect(script.requests.count == 3)
    }

    /// Cancelling during the wait before a retry ends the call at once, with the error that caused the wait.
    @Test(.timeLimit(.minutes(1))) func cancelStopsRetrying() async throws {
        let script = Script([.drop, .status(200, try appFixture("app-receipt-returned"))])
        let client = script.client()
        let binding = try binding()
        let call = Task { try await client.answer(id: "a_7Qm2xVb9Lk3pR8sT", binding, retryDelay: .seconds(30)) }
        while script.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let started = ContinuousClock.now
        call.cancel()
        await #expect(throws: AppError.self) { try await call.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(script.requests.count == 1)
    }

    @Test func receiptIsReadByID() async throws {
        let script = Script([.status(200, try appFixture("app-answer-conflict"))])
        let receipt = try await script.client().receipt(answerID: "a_Hc4nW8dZ1qYf6uJe")
        #expect(receipt.fate == .conflict("decision_revision_changed"))
        #expect(script.requests.first?.path == "/api/apps/v1/answers/a_Hc4nW8dZ1qYf6uJe")
        #expect(script.requests.first?.method == "GET")
    }
}

@Suite struct AppEventTests {
    @Test func streamYieldsInvalidationsResetsAndHeartbeats() async throws {
        let sse = """
            event: invalidate
            id: Y3Vyc29yLTE
            data: {"kind":"invalidate","cursor":"Y3Vyc29yLTE","requestId":null}

            event: heartbeat
            data: {"kind":"heartbeat"}

            event: reset
            data: {"kind":"reset","reason":"continuity-unproven"}


            """
        let script = Script([.status(200, Data(sse.utf8))])
        var seen: [AppEvent] = []
        for try await event in script.client(token: "orapp_abc").events(after: "Y3Vyc29yLTA") { seen.append(event) }
        #expect(seen == [.invalidate(cursor: "Y3Vyc29yLTE"), .heartbeat, .reset])
        #expect(script.requests.first?.path == "/api/apps/v1/events")
        #expect(script.requests.first?.authorization == "Bearer orapp_abc")
        #expect(script.requests.first?.lastEventID == "Y3Vyc29yLTA")
    }

    @Test func revokedStreamIsUnpaired() async {
        let script = Script([.status(401)])
        await #expect(throws: AppError.unpaired) {
            for try await _ in script.client().events() {}
        }
    }
}

@Suite struct AppCredentialOwnerTests {
    @Test func issueSendsExactlyTheDaemonsFieldsWithTheOwnerBearer() async throws {
        let script = Script([.status(201, try appFixture("app-credential"))])
        let owner = DaemonHTTP(baseURL: script.baseURL, session: script.session, bearer: "owner-token")
        let credential = try await owner.issueAppCredential(for: ["human-example@external"])
        #expect(credential.id == "70cfe276-ec37-44e5-ae7c-6515ef5ff2ee")

        let seen = try #require(script.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.path == "/api/apps/v1/credentials")
        #expect(seen.authorization == "Bearer owner-token")
        let body = try #require(try JSONSerialization.jsonObject(with: seen.body ?? Data()) as? [String: Any])
        #expect(body["appId"] as? String == AppCredential.remoteAppID)
        #expect(body["actors"] as? [String] == ["human-example@external"])
        #expect(body["job"] as? String == "human-answer")
        #expect(body["attribution"] as? String == "app-attributed")
        #expect(body.count == 4)
    }

    @Test func revokeDeletesByID() async throws {
        let script = Script([.status(200, Data(#"{"revoked":true}"#.utf8))])
        try await DaemonHTTP(baseURL: script.baseURL, session: script.session).revokeAppCredential(id: "cred-1")
        #expect(script.requests.first?.method == "DELETE")
        #expect(script.requests.first?.path == "/api/apps/v1/credentials/cred-1")
    }

    /// A daemon too old for the contract has no credentials route.
    @Test func issueOnAnOldDaemonSaysSo() async {
        let script = Script([.status(404, Data("Not Found".utf8))])
        await #expect(throws: DaemonError.http(status: 404, path: "/api/apps/v1/credentials")) {
            try await DaemonHTTP(baseURL: script.baseURL, session: script.session)
                .issueAppCredential(for: ["human-example@external"])
        }
    }
}

import Foundation
import RigFixtures
import Synchronization
import Testing

@testable import RigClient

@Suite struct DaemonHTTPQueryTests {
    /// Each test uses its own host, so parallel tests don't read each other's requests.
    func client(_ host: String) -> DaemonHTTP {
        DaemonHTTP(baseURL: URL(string: "http://\(host).query.test")!, session: QueryProtocol.session)
    }

    func query(_ host: String) -> [String: String] {
        let url = QueryProtocol.lastURL.withLock { $0["\(host).query.test"] }
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func openRowsOfARigAskForTheOpenStatesOnly() async throws {
        _ = try await client("open").openRows(rig: "openrig-app")
        #expect(query("open") == ["rig": "openrig-app", "state": "pending,in-progress,blocked", "limit": "500"])
    }

    @Test func closedRowsAskForEveryClosedStateUpdatedSinceATime() async throws {
        let since = Date(timeIntervalSince1970: 1_795_000_000.25)
        _ = try await client("closed").closedRows(rig: "openrig-app", since: since)
        let sent = query("closed")
        #expect(sent["rig"] == "openrig-app")
        #expect(
            Set(sent["state"]?.split(separator: ",") ?? [])
                == ["done", "handed-off", "canceled", "denied", "failed"])
        #expect(sent["sort"] == "updated")
        #expect(sent["limit"] == "500")
        #expect(sent["updatedSince"] == "2026-11-18T11:06:40.250Z")
    }

    @Test func openRowsToAPersonAreUnchanged() async throws {
        _ = try await client("person").openRows(to: "artem@external")
        #expect(
            query("person") == [
                "destinationSession": "artem@external", "state": "pending,in-progress,blocked", "limit": "200",
            ])
    }

    /// A recorded cancel, with watchdog transitions before it. No denied or failed row was on record, so the last
    /// transition's state is swapped for each finished state.
    @Test(arguments: ["done", "canceled", "handed-off", "denied", "failed"])
    func closedByIsTheActorWhoMovedTheRowIntoAFinishedState(state: String) async throws {
        let recorded = try String(decoding: RigFixtures.data("transitions-canceled"), as: UTF8.self)
        let host = "closer-\(state)"
        QueryProtocol.bodies.withLock {
            $0["\(host).query.test"] = Data(
                recorded.replacingOccurrences(of: #""state": "canceled""#, with: #""state": "\#(state)""#).utf8)
        }
        #expect(try await client(host).closedBy(qitem: "q-1") == "operator-human@kernel")
    }

    @Test func closedByIsNilWhileNoTransitionFinishedTheRow() async throws {
        let recorded = try String(decoding: RigFixtures.data("transitions-canceled"), as: UTF8.self)
        QueryProtocol.bodies.withLock {
            $0["open-closer.query.test"] = Data(
                recorded.replacingOccurrences(of: #""state": "canceled""#, with: #""state": "pending""#).utf8)
        }
        #expect(try await client("open-closer").closedBy(qitem: "q-1") == nil)
    }
}

/// Global sink: these tests install it, so they run one at a time and keep only their own host's records.
@Suite(.serialized) struct RequestLogTests {
    func recording(_ host: String, while body: () async -> Void) async -> [RequestRecord] {
        let records = Mutex<[RequestRecord]>([])
        RequestLog.install { record in records.withLock { $0.append(record) } }
        await body()
        RequestLog.install(nil)
        return records.withLock { $0 }.filter { $0.target.hasPrefix("/\(host)/") }
    }

    @Test func eachRequestIsReportedWithItsTargetStatusAndSize() async throws {
        let client = DaemonHTTP(baseURL: URL(string: "http://log.query.test/one")!, session: QueryProtocol.session)
        let records = await recording("one") { _ = try? await client.openRows(rig: "r") }
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.method == "GET")
        #expect(record.target == "/one/api/queue/list?limit=500&rig=r&state=pending,in-progress,blocked")
        #expect(record.status == 200)
        #expect(record.bytes == 2)
        #expect(record.milliseconds >= 0)
    }

    @Test func aRequestWithNoResponseHasNoStatus() async {
        let client = DaemonHTTP(baseURL: URL(string: "http://fail.query.test/two")!, session: QueryProtocol.session)
        let records = await recording("two") { _ = try? await client.health() }
        #expect(records.map(\.status) == [nil])
        #expect(records.map(\.bytes) == [0])
    }

    @Test func aLineIsSpaceSeparatedWithADashForNoStatus() {
        let start = Date(timeIntervalSince1970: 1_795_000_000.125)
        let ok = RequestRecord(
            start: start, method: "GET", target: "/api/queue/list?rig=r", status: 200, bytes: 1234, milliseconds: 41)
        #expect(ok.line == "2026-11-18T11:06:40.125Z GET /api/queue/list?rig=r 200 1234 41")
        var failed = ok
        failed.status = nil
        #expect(failed.line.hasSuffix(" - 1234 41"))
    }

    @Test func theFileSinkAppendsOneLinePerRequest() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "requests-\(UUID().uuidString).log").path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "earlier\n".write(toFile: path, atomically: true, encoding: .utf8)
        let sink = try #require(RequestLog.appending(toFile: path))
        let record = RequestRecord(
            start: Date(timeIntervalSince1970: 0), method: "GET", target: "/healthz", status: 200, bytes: 2,
            milliseconds: 1)
        sink(record)
        sink(record)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["earlier", Substring(record.line), Substring(record.line)])
    }

    @Test func aFileThatCannotBeOpenedIsNoSink() {
        #expect(RequestLog.appending(toFile: "/no/such/folder/requests.log") == nil)
    }
}

/// Records the URL of the last request to each *.query.test host and answers the host's body in `bodies`, or `[]`.
/// A host starting with `fail.` fails with no response.
final class QueryProtocol: URLProtocol, @unchecked Sendable {
    static let lastURL = Mutex<[String: URL]>([:])
    static let bodies = Mutex<[String: Data]>([:])
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QueryProtocol.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".query.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lastURL.withLock { $0[url.host ?? ""] = url }
        if url.host?.hasPrefix("fail.") == true {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.bodies.withLock { $0[url.host ?? ""] } ?? Data("[]".utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

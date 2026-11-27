import Foundation
import RigModel

/// One answer to an ask's questions.
public enum AskAnswer: Sendable, Equatable {
    case choice(question: String, option: String)
    /// The person's own words, recorded under the first question still unanswered.
    case words(String)
}

public enum DaemonError: Error, Sendable, Equatable {
    /// Nothing answered: the daemon is stopped or the port is wrong.
    case unreachable(String)
    case http(status: Int, path: String)
    case decoding(path: String, message: String)
    /// The daemon said no, with its own reason (e.g. `answer_not_recorded`).
    case refused(code: String, message: String)
}

/// Access to the daemon's HTTP API. Writes go through the `rig` CLI, except answering an ask's questions: the
/// `answer` verb has no CLI wrapper, only `POST /api/mission-control/action`.
public struct DaemonHTTP: Sendable {
    public var baseURL: URL
    var session: URLSession
    var timeout: TimeInterval
    /// Sent on every request, as the CLI does, for daemons with an operator bearer configured.
    public var bearer: String?

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 5, bearer: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
        self.bearer = bearer
    }

    private func authorize(_ request: inout URLRequest) {
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    }

    public func health() async throws(DaemonError) -> DaemonHealth {
        try await get("/healthz")
    }

    public func rigs() async throws(DaemonError) -> [RigSummary] {
        try await get("/api/ps")
    }

    /// The rig specs in the library, built in and the person's own.
    public func rigSpecs() async throws(DaemonError) -> [SpecEntry] {
        try await get("/api/specs/library", query: ["kind": "rig"])
    }

    public func specReview(id: String) async throws(DaemonError) -> SpecReview {
        try await get("/api/specs/library/\(id)/review")
    }

    public func graph(rigID: String) async throws(DaemonError) -> RigGraph {
        try await get("/api/rigs/\(rigID)/graph")
    }

    /// All queue rows whose source or destination is in the rig, newest first.
    public func queue(rigName: String, limit: Int = 500) async throws(DaemonError) -> [QItem] {
        try await get("/api/queue/list", query: ["rig": rigName, "limit": String(limit)])
    }

    /// Open rows addressed to `destination`, across every rig. (`attention=1` would leave out FYIs.)
    public func openRows(to destination: String, limit: Int = 200) async throws(DaemonError) -> [QItem] {
        try await get(
            "/api/queue/list",
            query: ["destinationSession": destination, "state": Self.openStates, "limit": String(limit)])
    }

    /// Open rows whose source or destination is in the rig. The daemon filters by state before its per-row work, so
    /// this costs it far less than `queue(rigName:)`.
    public func openRows(rig rigName: String, limit: Int = 500) async throws(DaemonError) -> [QItem] {
        try await get("/api/queue/list", query: ["rig": rigName, "state": Self.openStates, "limit": String(limit)])
    }

    /// Closed rows of the rig updated at or after `since`, most recently updated first.
    public func closedRows(rig rigName: String, since: Date, limit: Int = 500) async throws(DaemonError) -> [QItem] {
        try await get(
            "/api/queue/list",
            query: [
                "rig": rigName, "state": Self.closedStates, "limit": String(limit), "sort": "updated",
                "updatedSince": since.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            ])
    }

    static let openStates = "pending,in-progress,blocked"
    /// Every state the daemon (0.7.22, `QUEUE_STATES`) has besides the open ones.
    static let closedStates = "done,handed-off,canceled,denied,failed"

    public func seatStatus(session: String) async throws(DaemonError) -> SeatStatusReport {
        try await get("/api/seat/status/\(session)")
    }

    /// Every workflow instance the daemon knows, with the spec each one started from.
    public func workflows() async throws(DaemonError) -> [WorkflowInstance] {
        try await get("/api/workflow/list")
    }

    /// People and shared channels registered with the gateway, and the default person.
    public func participants() async throws(DaemonError) -> GatewayParticipants {
        try await get("/api/gateway/participants")
    }

    /// Who closed a row: the actor of its last transition into a finished state. The row itself doesn't say.
    public func closedBy(qitem id: String) async throws(DaemonError) -> String? {
        struct Transition: Decodable {
            var actorSession: String?
            var state: String?
        }
        let transitions: [Transition] = try await get("/api/queue/\(id)/transitions")
        let finished: Set<String?> = ["done", "canceled", "handed-off", "denied", "failed"]
        return transitions.last { finished.contains($0.state) }?.actorSession
    }

    public func qitem(id: String) async throws(DaemonError) -> QItem {
        try await get("/api/queue/\(id)")
    }

    /// Records one answer on an ask, as `actor`: a choice, or the person's own words. When the last question is
    /// answered, the daemon returns the answers to the asker as one reply row and closes the ask.
    public func answer(qitem id: String, _ answer: AskAnswer, as actor: String) async throws(DaemonError) {
        var body: [String: String] = ["verb": "answer", "qitemId": id, "actorSession": actor]
        switch answer {
        case .choice(let question, let option):
            body["questionId"] = question
            body["optionId"] = option
        case .words(let text):
            body["decision"] = text
        }
        let path = "/api/mission-control/action"
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Names the actor at this hop, so the daemon records the person (transport provenance).
        request.setValue(actor, forHTTPHeaderField: "X-OpenRig-Session")
        request.httpBody = try? JSONEncoder().encode(body)
        authorize(&request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        struct Refusal: Decodable {
            var error: String?
            var message: String?
        }
        // A refusal body counts whatever the status, in case one ever comes back with a 2xx.
        if let refusal = try? JSONDecoder().decode(Refusal.self, from: data), let code = refusal.error {
            throw .refused(code: code, message: refusal.message ?? code)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(status: http.statusCode, path: path)
        }
    }

    /// Whether the daemon's operator gate lets this client's writes through, checked without changing anything: an
    /// answer to a row that doesn't exist passes the gate and is then refused as not found.
    public enum OperatorAuth: Sendable, Equatable {
        case accepted
        /// The gate said no: the token is wrong, or the daemon wants one and none was sent.
        case rejected(status: Int)
        case unreachable
    }

    public func checkOperatorAuth(as actor: String) async -> OperatorAuth {
        let body = [
            "verb": "answer", "qitemId": "qitem-00000000000000-auth-check", "actorSession": actor, "decision": "-",
        ]
        var request = URLRequest(url: baseURL.appending(path: "/api/mission-control/action"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(actor, forHTTPHeaderField: "X-OpenRig-Session")
        request.httpBody = try? JSONEncoder().encode(body)
        authorize(&request)
        guard let (_, response) = try? await send(request), let http = response as? HTTPURLResponse
        else { return .unreachable }
        return http.statusCode == 401 || http.statusCode == 403 ? .rejected(status: http.statusCode) : .accepted
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws(DaemonError) -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) })
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .http(status: http.statusCode, path: path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(path: path, message: String(describing: error))
        }
    }

    /// Every request goes through here, so the request log sees each one.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let start = Date()
        let clock = ContinuousClock.now
        var data: Data?
        var status: Int?
        defer {
            let elapsed = clock.duration(to: .now)
            let url = request.url
            let target = (url?.path() ?? "") + (url?.query().map { "?" + $0 } ?? "")
            RequestLog.report(
                RequestRecord(
                    start: start, method: request.httpMethod ?? "GET", target: target, status: status,
                    bytes: data?.count ?? 0,
                    milliseconds: Int(elapsed / .milliseconds(1))))
        }
        let (body, response) = try await session.data(for: request)
        data = body
        status = (response as? HTTPURLResponse)?.statusCode
        return (body, response)
    }
}

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

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 5) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func health() async throws(DaemonError) -> DaemonHealth {
        try await get("/healthz")
    }

    public func rigs() async throws(DaemonError) -> [RigSummary] {
        try await get("/api/ps")
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
            query: ["destinationSession": destination, "state": "pending,in-progress,blocked", "limit": String(limit)])
    }

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
        let finished: Set<String?> = ["done", "canceled", "handed-off"]
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws(DaemonError) -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) })
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
}

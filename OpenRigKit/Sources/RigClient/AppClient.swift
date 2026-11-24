import Foundation
import RigModel

public enum AppError: Error, Sendable, Equatable {
    /// No response: the daemon is off or out of reach, or the response was lost on the way back.
    case unreachable(String)
    /// 401: the credential was revoked or never valid. The phone is no longer paired.
    case unpaired
    /// The daemon has no phone-app contract, or not this version.
    case unsupportedDaemon
    /// The daemon answered with an error code, e.g. `answer_already_returned`.
    case refused(status: Int, code: String?, retrySameSubmission: Bool?)
    case decoding(path: String, message: String)

    /// Whether resending the same answer id and binding is safe and may finish it: after a lost response, and for
    /// every 503, as core-app.md's 503 table says. Never after a 409.
    public var retrySameSubmission: Bool {
        switch self {
        case .unreachable: true
        case .refused(let status, _, _): status == 503
        default: false
        }
    }
}

/// What `GET /events` says. It carries no data: on each event, read again.
public enum AppEvent: Sendable, Equatable {
    /// Something changed. Resume from `cursor` after a drop.
    case invalidate(cursor: String?)
    /// Continuity is lost: read everything again. The daemon closes the stream after it.
    case reset
    case heartbeat
}

/// The phone app's client for `/api/apps/v1`. Every call carries the app's own credential and acts as `actor`.
public struct AppClient: Sendable {
    public var baseURL: URL
    var token: String
    public var actor: String
    var session: URLSession
    var timeout: TimeInterval

    public init(baseURL: URL, token: String, actor: String, session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.token = token
        self.actor = actor
        self.session = session
        self.timeout = timeout
    }

    /// Any 404 here means the daemon doesn't offer this contract.
    public func capabilities() async throws(AppError) -> AppCapabilities {
        do {
            return try await send("GET", "capabilities", actor: false)
        } catch .refused(status: 404, _, _) {
            throw .unsupportedDaemon
        }
    }

    public func needsMe() async throws(AppError) -> AppNeedsMe {
        try await send("GET", "needs-me")
    }

    public func request(id: String) async throws(AppError) -> AppRequest {
        try await send("GET", "requests/\(id)")
    }

    public func result(requestID: String) async throws(AppError) -> AppResult {
        try await send("GET", "requests/\(requestID)/result")
    }

    /// The saved receipt, or how far an unfinished submission got. Reads never write.
    public func receipt(answerID: String) async throws(AppError) -> AppAnswerReceipt {
        try await send("GET", "answers/\(answerID)")
    }

    /// One attempt. Save `id` and `binding` before calling, so a crash can resend them.
    public func submit(id: String, _ binding: AppAnswerBinding) async throws(AppError) -> AppAnswerReceipt {
        try await send("POST", "answers/\(id)", actor: false, body: Self.body(binding))
    }

    /// Submits, resending the same id and the same bytes while `retrySameSubmission` allows. Throws the last error.
    /// A cancel stops it before the next attempt; the saved id and binding can be resent later.
    public func answer(
        id: String, _ binding: AppAnswerBinding, attempts: Int = 3, retryDelay: Duration = .seconds(1)
    ) async throws(AppError) -> AppAnswerReceipt {
        try await answer(id: id, body: Self.body(binding), attempts: attempts, retryDelay: retryDelay)
    }

    /// As `answer(id:_:)`, with the body already encoded, as an outbox saved it.
    public func answer(
        id: String, body: Data, attempts: Int = 3, retryDelay: Duration = .seconds(1)
    ) async throws(AppError) -> AppAnswerReceipt {
        var attempt = 1
        while true {
            do {
                return try await send("POST", "answers/\(id)", actor: false, body: body)
            } catch let failure where failure.retrySameSubmission && attempt < attempts && !Task.isCancelled {
                attempt += 1
                do { try await Task.sleep(for: retryDelay) } catch { throw failure }
            }
        }
    }

    /// One connection to the invalidation stream. Pass the last cursor seen to resume; the daemon sends `reset` when
    /// it can't. The stream ends when the connection does, or throws `AppError.unpaired` once revoked.
    public func events(after cursor: String? = nil) -> AsyncThrowingStream<AppEvent, any Error> {
        var request = URLRequest(url: url("events", actor: false), timeoutInterval: 60)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
        let (session, finalRequest) = (self.session, request)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw http.statusCode == 401
                            ? AppError.unpaired
                            : AppError.refused(status: http.statusCode, code: nil, retrySameSubmission: nil)
                    }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    // Split by hand: AsyncBytes.lines drops the blank line that ends each message.
                    for try await byte in bytes {
                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        if let message = parser.feed(String(decoding: line, as: UTF8.self)) {
                            continuation.yield(Self.event(message))
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sorted keys, so the same binding always gives the same bytes.
    public static func body(_ binding: AppAnswerBinding) throws(AppError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do { return try encoder.encode(binding) } catch { throw .decoding(path: "answers", message: "\(error)") }
    }

    static func event(_ message: SSEParser.Message) -> AppEvent {
        switch message.event {
        case "heartbeat": .heartbeat
        case "reset": .reset
        // An unknown kind also means "read again".
        default: .invalidate(cursor: message.id)
        }
    }

    func url(_ path: String, actor withActor: Bool = true) -> URL {
        var url = baseURL.appending(path: "/api/apps/v1/\(path)")
        guard withActor, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = [URLQueryItem(name: "actor", value: actor)]
        // The daemon reads "+" in a query as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        url = parts.url ?? url
        return url
    }

    func send<T: Decodable>(
        _ method: String, _ path: String, actor withActor: Bool = true, body: Data? = nil
    ) async throws(AppError) -> T {
        var request = URLRequest(url: url(path, actor: withActor), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 { throw .unpaired }
        guard (200..<300).contains(status) else {
            let refusal = try? JSONDecoder().decode(AppRefusal.self, from: data)
            throw .refused(status: status, code: refusal?.error, retrySameSubmission: refusal?.retrySameSubmission)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(path: path, message: String(describing: error))
        }
    }
}

/// The daemon's error body: `{error, ...details}`.
private struct AppRefusal: Decodable {
    var error: String?
    var retrySameSubmission: Bool?
}

/// Leaves the token out of `print`, `debugPrint` and `dump`, so a logged client doesn't leak it.
extension AppClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AppClient(\(actor) at \(baseURL.absoluteString))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL, "actor": actor]) }
}

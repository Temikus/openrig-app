import Foundation

/// One event from `GET /api/events`. The app treats events as "something changed" signals and refetches state.
public struct DaemonEvent: Sendable, Equatable {
    /// The daemon's `seq`; send it back as `Last-Event-ID` to resume.
    public var id: Int?
    public var type: String
    /// Only some event types carry a rig id; queue and seat-activity events don't.
    public var rigId: String?
    public var data: Data

    public init(id: Int?, type: String, rigId: String? = nil, data: Data = Data()) {
        self.id = id
        self.type = type
        self.rigId = rigId
        self.data = data
    }
}

/// Server-sent events framing (https://html.spec.whatwg.org/multipage/server-sent-events.html).
/// Feed it lines without their terminators; it returns a message at each blank line.
public struct SSEParser: Sendable {
    public struct Message: Sendable, Equatable {
        public var id: String?
        public var event: String?
        public var data: String
    }

    private var data: [String] = []
    private var event: String?
    private var id: String?
    private var sawField = false

    public init() {}

    public mutating func feed(_ line: String) -> Message? {
        if line.isEmpty {
            defer { data = []; event = nil; id = nil; sawField = false }
            guard sawField, !data.isEmpty else { return nil }
            return Message(id: id, event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        sawField = true
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        case "id" where !value.contains("\0"): id = String(value)
        default: break
        }
        return nil
    }
}

public enum EventStreamUpdate: Sendable, Equatable {
    case connected
    case event(DaemonEvent)
    case disconnected(String)
}

/// Live events from the daemon. Reconnects with `Last-Event-ID`, so no event is lost across a drop.
public struct EventStream: Sendable {
    public var baseURL: URL
    var session: URLSession
    /// The daemon sends no heartbeat; an idle connection is dropped and resumed after this long.
    var idleTimeout: TimeInterval

    public init(baseURL: URL, session: URLSession = .shared, idleTimeout: TimeInterval = 300) {
        self.baseURL = baseURL
        self.session = session
        self.idleTimeout = idleTimeout
    }

    /// One connection. `replay` asks for the newest n stored events; a `lastEventID` overrides it.
    /// `onOpen` runs once the daemon accepts the connection, before any event arrives.
    public func connect(
        replay: Int? = 0, lastEventID: Int? = nil, onOpen: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<DaemonEvent, any Error> {
        var components = URLComponents(url: baseURL.appending(path: "/api/events"), resolvingAgainstBaseURL: false)!
        if let replay { components.queryItems = [URLQueryItem(name: "replay", value: String(replay))] }
        var request = URLRequest(url: components.url!, timeoutInterval: idleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID") }
        let session = self.session
        let finalRequest = request

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw DaemonError.http(status: http.statusCode, path: "/api/events")
                    }
                    onOpen()
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        if let message = parser.feed(String(decoding: line, as: UTF8.self)) {
                            continuation.yield(Self.decode(message))
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

    /// Connects, yields events, and reconnects after drops until the consuming task is cancelled.
    public func updates(startingAfter lastEventID: Int? = nil) -> AsyncStream<EventStreamUpdate> {
        AsyncStream { continuation in
            let task = Task {
                var last = lastEventID
                var backoff: Duration = .milliseconds(500)
                while !Task.isCancelled {
                    do {
                        // URLSession hands over the response only once body bytes arrive, and a quiet
                        // daemon sends none. Asking for one already-seen event makes the connection show
                        // up at once; events are refresh signals, so a repeat is harmless.
                        let resume = last.map { max($0 - 1, 0) }
                        for try await event in connect(
                            replay: 1, lastEventID: resume, onOpen: { continuation.yield(.connected) })
                        {
                            backoff = .milliseconds(500)
                            if let id = event.id { last = id }
                            continuation.yield(.event(event))
                        }
                        continuation.yield(.disconnected("stream ended"))
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.yield(.disconnected(error.localizedDescription))
                    }
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decode(_ message: SSEParser.Message) -> DaemonEvent {
        struct Envelope: Decodable {
            var type: String?
            var rigId: String?
            var seq: Int?
        }
        let data = Data(message.data.utf8)
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return DaemonEvent(
            id: message.id.flatMap { Int($0) } ?? envelope?.seq,
            type: envelope?.type ?? message.event ?? "message",
            rigId: envelope?.rigId,
            data: data
        )
    }
}

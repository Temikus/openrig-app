import Foundation
import Synchronization

/// One request `DaemonHTTP` made to the daemon.
public struct RequestRecord: Sendable, Equatable {
    public var start: Date
    public var method: String
    /// Path and query, as sent: `/api/queue/list?limit=500&rig=openrig-app`.
    public var target: String
    /// Nil when no response came back.
    public var status: Int?
    /// Response body size.
    public var bytes: Int
    public var milliseconds: Int

    public init(start: Date, method: String, target: String, status: Int?, bytes: Int, milliseconds: Int) {
        self.start = start
        self.method = method
        self.target = target
        self.status = status
        self.bytes = bytes
        self.milliseconds = milliseconds
    }

    /// `<time> <method> <target> <status> <bytes> <ms>`, space-separated for awk. A failed request's status is `-`.
    public var line: String {
        let time = start.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "\(time) \(method) \(target) \(status.map(String.init) ?? "-") \(bytes) \(milliseconds)"
    }
}

/// Where every `DaemonHTTP` request in the process is reported (OPENRIG_DEBUG_REQUESTS). Off until a sink is set.
public enum RequestLog {
    public typealias Sink = @Sendable (RequestRecord) -> Void

    private static let sink = Mutex<Sink?>(nil)

    /// Replaces the sink; nil turns the log off.
    public static func install(_ newSink: Sink?) {
        sink.withLock { $0 = newSink }
    }

    static func report(_ record: RequestRecord) {
        sink.withLock { $0 }?(record)
    }

    /// A sink that appends one line per request to the file at `path`, creating it if needed. Nil when the file can't
    /// be opened.
    public static func appending(toFile path: String) -> Sink? {
        let manager = FileManager.default
        if !manager.fileExists(atPath: path), !manager.createFile(atPath: path, contents: nil) { return nil }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        _ = try? handle.seekToEnd()
        let file = LineFile(handle)
        return { file.write($0.line) }
    }
}

/// Serialises writes, so lines from concurrent requests don't interleave.
private final class LineFile: Sendable {
    private let handle: Mutex<FileHandle>

    init(_ handle: FileHandle) { self.handle = Mutex(handle) }

    func write(_ line: String) {
        handle.withLock { try? $0.write(contentsOf: Data((line + "\n").utf8)) }
    }
}

import Foundation
import RigModel
import Synchronization

/// An answer saved before it was sent. The contract says to resend exactly this id and body after an uncertain end,
/// so the body is kept as the bytes sent, and only to the pairing that sent it.
public struct PendingAnswer: Codable, Sendable, Equatable {
    public var id: String
    /// The pairing's credential. An entry from another pairing is dropped, never sent.
    public var credentialID: String
    public var requestID: String
    /// The exact `POST /answers/:id` body.
    public var body: Data

    public init(id: String, credentialID: String, requestID: String, body: Data) {
        self.id = id
        self.credentialID = credentialID
        self.requestID = requestID
        self.body = body
    }
}

public protocol AnswerOutbox: Sendable {
    func load() throws -> [PendingAnswer]
    func add(_ answer: PendingAnswer) throws
    func remove(id: String) throws
    func removeAll() throws
}

/// One JSON file. It holds the person's answers, so on the phone it's readable only while the phone is unlocked.
public struct FileAnswerOutbox: AnswerOutbox {
    public var url: URL

    public init(url: URL) { self.url = url }

    /// In the app's Application Support folder.
    public static func standard() -> FileAnswerOutbox {
        FileAnswerOutbox(url: URL.applicationSupportDirectory.appending(path: "pending-answers.json"))
    }

    /// A file that won't decode is moved aside, not read again, so it can't block every later Send.
    public func load() throws -> [PendingAnswer] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode([PendingAnswer].self, from: data)
        } catch {
            let stamp = Int(Date.now.timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appending(path: "pending-answers.damaged-\(stamp).json")
            try FileManager.default.moveItem(at: url, to: aside)
            return []
        }
    }

    public func add(_ answer: PendingAnswer) throws { try write(load().filter { $0.id != answer.id } + [answer]) }

    public func remove(id: String) throws { try write(load().filter { $0.id != id }) }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ answers: [PendingAnswer]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try JSONEncoder().encode(answers).write(to: url, options: [.atomic, .completeFileProtection])
        #else
            try JSONEncoder().encode(answers).write(to: url, options: .atomic)
        #endif
    }
}

/// For tests and previews.
public final class MemoryAnswerOutbox: AnswerOutbox {
    private let answers = Mutex<[PendingAnswer]>([])

    public init() {}

    public func load() throws -> [PendingAnswer] { answers.withLock { $0 } }
    public func add(_ answer: PendingAnswer) throws { answers.withLock { $0.append(answer) } }
    public func remove(id: String) throws { answers.withLock { $0.removeAll { $0.id == id } } }
    public func removeAll() throws { answers.withLock { $0.removeAll() } }
}

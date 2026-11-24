import Foundation
import RigModel
import Synchronization

/// An answer saved before it was sent. The contract says to resend exactly this id and body after an uncertain end.
public struct PendingAnswer: Codable, Sendable, Equatable {
    public var id: String
    public var binding: AppAnswerBinding

    public init(id: String, binding: AppAnswerBinding) {
        self.id = id
        self.binding = binding
    }
}

public protocol AnswerOutbox: Sendable {
    func load() throws -> [PendingAnswer]
    func add(_ answer: PendingAnswer) throws
    func remove(id: String) throws
}

/// One JSON file. It holds the person's answers, so on the phone it's readable only while the phone is unlocked.
public struct FileAnswerOutbox: AnswerOutbox {
    public var url: URL

    public init(url: URL) { self.url = url }

    /// In the app's Application Support folder.
    public static func standard() -> FileAnswerOutbox {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return FileAnswerOutbox(url: folder.appending(path: "pending-answers.json"))
    }

    public func load() throws -> [PendingAnswer] {
        guard FileManager.default.fileExists(atPath: url.path()) else { return [] }
        return try JSONDecoder().decode([PendingAnswer].self, from: Data(contentsOf: url))
    }

    public func add(_ answer: PendingAnswer) throws { try write(load().filter { $0.id != answer.id } + [answer]) }

    public func remove(id: String) throws { try write(load().filter { $0.id != id }) }

    private func write(_ answers: [PendingAnswer]) throws {
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
}

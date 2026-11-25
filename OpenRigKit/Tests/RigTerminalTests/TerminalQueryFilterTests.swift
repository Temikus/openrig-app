import Foundation
import Testing

@testable import RigTerminal

@Suite struct TerminalQueryFilterTests {
    /// What a tmux 3.8 client wrote to its terminal as it attached to a throwaway shell pane (`TERM=xterm-256color`).
    func attachOutput() throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(forResource: "tmux-attach-output", withExtension: "bin", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    static let queries: [String] = [
        "\u{1B}[c", "\u{1B}[>c", "\u{1B}[>q", "\u{1B}]10;?\u{1B}\\", "\u{1B}]11;?\u{1B}\\", "\u{1B}[18t", "\u{1B}[14t",
        "\u{1B}[?996n",
    ]

    func filtered(_ bytes: [UInt8], chunk: Int? = nil) -> [UInt8] {
        var filter = TerminalQueryFilter()
        let size = chunk ?? bytes.count
        return stride(from: 0, to: bytes.count, by: size).flatMap {
            filter.filter(bytes[$0..<min($0 + size, bytes.count)])
        }
    }

    /// Every query the live client sent is in the capture, and the filter removes exactly those bytes.
    @Test func takesOutTheClientsQueriesAndNothingElse() throws {
        let raw = try attachOutput()
        var expected = raw
        for query in Self.queries {
            let q = Array(query.utf8)
            let at = try #require(expected.firstRange(of: q), "\(query.debugDescription) is in the capture")
            expected.removeSubrange(at)
        }
        let out = filtered(raw)
        #expect(out == expected)
        #expect(raw.count - out.count == Self.queries.reduce(0) { $0 + $1.utf8.count })
    }

    /// tmux's reads split the stream anywhere, even inside a query.
    @Test func aQuerySplitAcrossChunksIsStillTakenOut() throws {
        let raw = try attachOutput()
        let whole = filtered(raw)
        for size in [1, 2, 3, 5, 7, 64] {
            #expect(filtered(raw, chunk: size) == whole, "chunks of \(size)")
        }
    }

    /// Lookalikes a pane draws pass untouched: a window-size command, a title, a cursor report, colours and modes.
    @Test func keepsEverythingThatIsntAQuery() {
        let text =
            "\u{1B}[8;24;80t\u{1B}[22;0;0t\u{1B}]0;title\u{07}\u{1B}]10;#ffffff\u{1B}\\\u{1B}[?2004h\u{1B}[6n"
            + "\u{1B}[1;31mred\u{1B}[m\u{1B}[2J\u{1B}=\u{1B}(Bplain ❯ text"
        let bytes = Array(text.utf8)
        #expect(filtered(bytes) == bytes)
        #expect(filtered(bytes, chunk: 1) == bytes)
    }

    /// A long unfinished sequence isn't held back: nothing the pane drew waits for more output than a query's length.
    @Test func aLongUnfinishedSequenceIsPassedOn() {
        var filter = TerminalQueryFilter()
        let title = Array("\u{1B}]0;".utf8) + Array(repeating: UInt8(ascii: "x"), count: 100)
        #expect(filter.filter(title[...]) == title)
        #expect(filter.filter(Array("\u{1B}[".utf8)[...]).isEmpty, "a short start waits for the rest")
        #expect(filter.filter(Array("1mok".utf8)[...]) == Array("\u{1B}[1mok".utf8))
    }
}

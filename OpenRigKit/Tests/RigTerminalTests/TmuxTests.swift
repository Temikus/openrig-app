import Foundation
import SwiftTerm
import Testing

@testable import RigTerminal

@Suite struct PaneCaptureTests {
    @Test func batchArgsChainCommandsPerPane() {
        let args = PaneCapture.batchArgs(panes: ["%1", "%2"])
        #expect(args.filter { $0 == ";" }.count == 3)
        #expect(args.filter { $0 == "capture-pane" }.count == 2)
    }

    @Test func parseSplitsPanesAndKeepsBlankRows() {
        let output = """
            @@openrig-pane %1 10 3 2 1 1
            one

            three
            @@openrig-pane %2 5 2 0 0
            \u{1B}[31mred\u{1B}[0m
            last

            """
        let snaps = PaneCapture.parse(output)
        #expect(snaps["%1"]?.lines == ["one", "", "three"])
        #expect(snaps["%1"]?.cols == 10 && snaps["%1"]?.cursorY == 1)
        #expect(snaps["%1"]?.statusRows == 1)
        #expect(snaps["%2"]?.statusRows == 0)
        #expect(snaps["%2"]?.lines == ["\u{1B}[31mred\u{1B}[0m", "last"])
    }

    @Test func malformedMarkerIsSkipped() {
        let snaps = PaneCapture.parse("@@openrig-pane %1 x y\nignored\n@@openrig-pane %2 1 1 0 0\nok\n")
        #expect(snaps.keys.sorted() == ["%2"])
    }

    @Test func tailSkipsBlankRowsBelowTheContent() {
        let snap = PaneSnapshot(
            pane: "%1", cols: 10, rows: 6, cursorX: 0, cursorY: 2,
            lines: ["a", "b", "\u{1B}[31m> \u{1B}[0m", "", "\u{1B}[0m", ""])
        let terminal = HeadlessTerminal(cols: 10, rows: 2)
        terminal.feed(snap.ansi(lastRows: 2))
        #expect(terminal.text(row: 0) == "b")
        #expect(terminal.text(row: 1) == ">")
        #expect(terminal.cursor == (0, 1))
        // The live view lines up on the same row.
        #expect(snap.contentEnd == 3)
        var below = snap
        below.cursorY = 4
        #expect(below.contentEnd == 5, "a cursor under the text counts too")
    }

    @Test func tailOfPaneMovesTheCursor() throws {
        let snap = PaneSnapshot(pane: "%1", cols: 10, rows: 4, cursorX: 2, cursorY: 3, lines: ["a", "b", "c", "d"])
        let terminal = HeadlessTerminal(cols: 10, rows: 2)
        terminal.feed(snap.ansi(lastRows: 2))
        #expect(terminal.text(row: 0) == "c")
        #expect(terminal.text(row: 1) == "d")
        #expect(terminal.cursor == (2, 1))
    }
}

/// A SwiftTerm terminal with no view, for checking what bytes render to.
final class HeadlessTerminal: TerminalDelegate {
    var terminal: Terminal!

    init(cols: Int, rows: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
    }

    func feed(_ bytes: [UInt8]) { terminal.feed(byteArray: bytes) }
    // trimRight keeps styled trailing spaces, so trim whitespace here too.
    func text(row: Int) -> String {
        (terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "").replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
    }
    var cursor: (Int, Int) { (terminal.buffer.x, terminal.buffer.y) }
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Runs against a throwaway tmux server on a private socket, never the user's.
@Suite(
    .serialized,
    .enabled("needs tmux") { Tmux.searchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) } })
struct TmuxIntegrationTests {
    let tmux: Tmux
    let dir: URL

    init() async throws {
        dir = URL(filePath: "/tmp").appending(path: "openrig-tmux-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = try #require(Tmux.searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) })
        tmux = Tmux(executable: URL(filePath: path), socketPath: dir.appending(path: "s").path())
        for name in ["one@test", "two@test"] {
            try await tmux.run([
                "-f", "/dev/null", "new-session", "-d", "-s", name, "-x", "40", "-y", "10",
                "printf '\\033[31mRED\\033[0m \(name)\\n'; sleep 600",
            ])
        }
    }

    func cleanUp() async {
        _ = try? await tmux.run(["kill-server"])
        try? FileManager.default.removeItem(at: dir)
    }

    func panes() async throws -> [String] {
        try await tmux.run(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").map(String.init)
    }

    func waitFor(isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("condition never became true")
    }

    @Test func capturedBytesRender() async throws {
        let ids = try await panes()
        try await waitFor { await tmux.snapshots(panes: ids).values.allSatisfy { $0.lines.joined().contains("RED") } }
        let snaps = await tmux.snapshots(panes: ids + ["%999"])
        #expect(snaps.count == 2, "a missing pane is skipped, not fatal")
        let snap = try #require(snaps[ids[0]])
        #expect(snap.cols == 40 && snap.rows == 10)
        #expect(snap.statusRows == 1, "tmux's status bar is on by default")
        #expect(snap.lines[0].contains("\u{1B}["), "colours survive the capture")

        let screen = HeadlessTerminal(cols: snap.cols, rows: snap.rows)
        screen.feed(snap.ansi())
        #expect(screen.text(row: 0).hasPrefix("RED "))
        let red = screen.terminal.getLine(row: 0)![0].attribute.fg
        #expect(red != Attribute.Color.defaultColor)
        await cleanUp()
    }

    @Test @MainActor func focusKeepsExactlyOneClient() async throws {
        let focus = FocusedAttach(tmux: tmux)
        func count(_ s: String) async throws -> Int { try await tmux.clients(session: s).count }

        let first = focus.focus(session: "one@test", cols: 40, rows: 10)
        try await waitFor { try await count("one@test") == 1 }
        // A view that subscribes after tmux's first paint still gets the screen.
        try await Task.sleep(for: .milliseconds(500))
        let received = Received()
        let old = first.subscribe { _ in }
        first.subscribe { received.append($0) }
        try await waitFor { String(decoding: received.bytes, as: UTF8.self).contains("one@test") }
        // SwiftUI builds a tile's new view before dismantling the old one: the old view leaving
        // must not cut off the new one.
        first.unsubscribe(old)
        // Typing goes through the attached client.
        first.send(ArraySlice("echo typed-here\r".utf8))
        try await waitFor { String(decoding: received.bytes, as: UTF8.self).contains("typed-here") }

        focus.focus(session: "two@test", cols: 40, rows: 10)
        try await waitFor {
            let one = try await count("one@test")
            let two = try await count("two@test")
            return one == 0 && two == 1
        }

        focus.release()
        try await waitFor { try await count("two@test") == 0 }
        await cleanUp()
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    func append(_ slice: ArraySlice<UInt8>) { lock.withLock { data.append(contentsOf: slice) } }
    var bytes: [UInt8] { lock.withLock { data } }
}

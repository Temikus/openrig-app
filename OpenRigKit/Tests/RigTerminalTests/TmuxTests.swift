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

    /// Claude Code's input box (rule, ❯ line, rule, status lines) is the same on every seat; small tiles
    /// show the transcript above it. Copied from a live pane.
    @Test func transcriptStopsAtTheInputBox() {
        let rule = String(repeating: "─", count: 30)
        let snap = PaneSnapshot(
            pane: "%1", cols: 40, rows: 8, cursorX: 2, cursorY: 4,
            lines: [
                "⏺ Read file", "  \u{1B}[2mdone\u{1B}[0m", "", "\u{1B}[2m\(rule) dev-b1@r ─\u{1B}[0m", "❯ ",
                "\(rule)──────────", "  ⏵⏵ auto mode on", "                 /rc",
            ])
        #expect(snap.transcriptEnd == 2, "blank line above the box is trimmed too")
        let terminal = HeadlessTerminal(cols: 40, rows: 2)
        terminal.feed(snap.ansi(lastRows: 2, transcriptOnly: true))
        #expect(terminal.text(row: 0) == "⏺ Read file")
        #expect(terminal.text(row: 1) == "  done")
        #expect(!terminal.cursorVisible, "the cursor belongs to the input box, which isn't shown")
        #expect(snap.text(lastRows: 2, transcriptOnly: true) == "⏺ Read file\n  done", "VoiceOver reads what's drawn")

        // No input box: same as the plain tail.
        let plain = PaneSnapshot(pane: "%1", cols: 10, rows: 3, cursorX: 0, cursorY: 2, lines: ["a", "b", "$ "])
        #expect(plain.transcriptEnd == plain.contentEnd)
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

@Suite struct PaneHistoryTests {
    @Test func captureDropsTheBlankRowsUnderTheText() {
        let history = PaneHistory(captured: "one\n\ntwo\n\n\n")
        #expect(history.lines == ["one", "", "two"])
    }

    @Test func olderLinesLandInScrollback() {
        let history = PaneHistory(lines: (1...30).map { "line \($0)" })
        let terminal = HeadlessTerminal(cols: 20, rows: 10)
        terminal.feed(history.ansi())
        #expect(terminal.text(row: 9) == "line 30", "the bottom shows the pane's last line")
        #expect(terminal.terminal.buffer.yDisp == 20, "the other 20 lines are above, to scroll back to")
        let first = terminal.terminal.getScrollInvariantLine(row: 0)?.translateToString(trimRight: true)
        #expect(first == "line 1")
    }

    @Test func aFullWidthLineDoesNotAddABlankRow() {
        let history = PaneHistory(lines: ["0123456789", "next"])
        let terminal = HeadlessTerminal(cols: 10, rows: 2)
        terminal.feed(history.ansi())
        #expect(terminal.text(row: 0) == "0123456789")
        #expect(terminal.text(row: 1) == "next")
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
    private(set) var cursorVisible = true
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func hideCursor(source: Terminal) { cursorVisible = false }
    func showCursor(source: Terminal) { cursorVisible = true }
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

    @Test func historyReachesPastTheScreen() async throws {
        try await tmux.run([
            "-f", "/dev/null", "new-session", "-d", "-s", "long@test", "-x", "40", "-y", "10", "seq 1 50; sleep 600",
        ])
        let pane = try await tmux.run(["display-message", "-p", "-t", "=long@test", "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await waitFor { await tmux.history(pane: pane)?.lines.last == "50" }
        let history = try #require(await tmux.history(pane: pane))
        #expect(history.lines.first == "1", "lines scrolled off the 10-row screen are included")
        #expect(history.lines.count == 50)
        #expect(await tmux.history(pane: "%999") == nil)
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

    /// Regression: see `Tmux.attachArgs`.
    @Test func attachShowsSymbolsWithoutALocale() async throws {
        let line = "❯ ⏵⏵ ← ─"
        try await tmux.run([
            "-f", "/dev/null", "new-session", "-d", "-s", "utf8@test", "-x", "40", "-y", "10",
            "printf '\(line)\\n'; sleep 600",
        ])
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key == "LANG" || key.hasPrefix("LC_") { environment[key] = nil }
        let attach = AttachSession(tmux: tmux, session: "utf8@test", cols: 40, rows: 10, environment: environment)
        let received = Received()
        attach.subscribe { received.append($0) }
        func firstRow() -> String {
            let screen = HeadlessTerminal(cols: 40, rows: 10)
            screen.feed(received.bytes)
            return screen.text(row: 0)
        }
        try await waitFor { firstRow() == line }
        #expect(firstRow() == line)
        attach.close()
        await cleanUp()
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    func append(_ slice: ArraySlice<UInt8>) { lock.withLock { data.append(contentsOf: slice) } }
    var bytes: [UInt8] { lock.withLock { data } }
}

@Suite struct PanOffsetTests {
    func snap(rows: Int, cursorY: Int) -> PaneSnapshot {
        PaneSnapshot(pane: "%1", cols: 80, rows: rows, cursorX: 0, cursorY: cursorY, lines: [])
    }

    @Test func aClientAsTallAsThePaneIsntPanned() {
        #expect(snap(rows: 25, cursorY: 20).panOffset(clientRows: 25) == 0)
        #expect(snap(rows: 25, cursorY: 20).panOffset(clientRows: 30) == 0)
    }

    /// Claude Code hides its cursor on the input line near the bottom; tmux then shows the top, so pan down.
    @Test func aCursorNearTheBottomShowsTheBottom() {
        #expect(snap(rows: 25, cursorY: 20).panOffset(clientRows: 10) == 15)
        #expect(snap(rows: 120, cursorY: 119).panOffset(clientRows: 78) == 42)
    }

    /// A full-screen app with its cursor near the top keeps it in view, one row from the top edge.
    @Test func aCursorHigherUpStaysInView() {
        #expect(snap(rows: 40, cursorY: 3).panOffset(clientRows: 10) == 2)
        #expect(snap(rows: 40, cursorY: 0).panOffset(clientRows: 10) == 0)
    }

    /// A full-screen app that hides its cursor parks it in a corner (`rig`'s operator TUI: bottom right of a 120-row
    /// pane). Its menus are at the top, so show the top rather than the parked cursor.
    @Test func aFullScreenAppWithAHiddenCursorShowsTheTop() {
        var tui = snap(rows: 120, cursorY: 119)
        tui.alternateScreen = true
        tui.cursorVisible = false
        #expect(tui.panOffset(clientRows: 40) == 0)
        // An editor on the alternate screen shows its cursor: keep following it.
        tui.cursorVisible = true
        #expect(tui.panOffset(clientRows: 40) == 80)
    }

    @Test func parsesTheScreenAndCursorFlags() {
        let output = "@@openrig-pane %7 200 120 199 119 1 1 0\nline\n"
        let snap = PaneCapture.parse(output)["%7"]
        #expect(snap?.alternateScreen == true)
        #expect(snap?.cursorVisible == false)
        // Older marker lines without the flags read as the main screen with a visible cursor.
        let old = PaneCapture.parse("@@openrig-pane %7 200 120 199 119 1\n")["%7"]
        #expect(old?.alternateScreen == false)
        #expect(old?.cursorVisible == true)
    }
}

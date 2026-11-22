import Foundation

/// A pane's scrollback and screen, oldest line first, as `capture-pane -e -S -` prints it (SGR escapes kept).
/// tmux keeps it whether or not the app is open, up to the pane's `history-limit`.
public struct PaneHistory: Sendable, Equatable {
    public var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    /// Parses `capture-pane` output, dropping the blank rows under the last line of text.
    public init(captured output: String) {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, strippingEscapes(last).trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        self.lines = lines
    }

    /// Bytes that draw every line on a terminal of the pane's width. All but the last screenful scroll into the
    /// terminal's scrollback, so it needs room for `lines.count` lines.
    public func ansi() -> [UInt8] {
        // Clear the screen, then the scrollback: a redraw after a font change must not stack a second copy.
        var text = "\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[3J"
        text += lines.map { "\u{1B}[0m" + $0 }.joined(separator: "\r\n")
        text += "\u{1B}[?25l"
        return Array(text.utf8)
    }
}

extension Tmux {
    /// The pane's whole history and screen, or nil when tmux can't capture it (the pane is gone).
    public func history(pane: String) async -> PaneHistory? {
        guard let output = try? await run(["capture-pane", "-p", "-e", "-S", "-", "-t", pane]) else { return nil }
        return PaneHistory(captured: output)
    }
}

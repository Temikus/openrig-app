import Foundation

/// One pane's visible screen, as `capture-pane -e` prints it (SGR escapes kept), plus its geometry.
public struct PaneSnapshot: Sendable, Equatable {
    public var pane: String
    public var cols: Int
    public var rows: Int
    public var cursorX: Int
    public var cursorY: Int
    /// Rows tmux's status bar adds to an attached client (0 when the bar is off).
    public var statusRows: Int = 0
    /// Screen lines, top to bottom.
    public var lines: [String]
    public var capturedAt: Date

    public init(
        pane: String, cols: Int, rows: Int, cursorX: Int, cursorY: Int, lines: [String], capturedAt: Date = .now
    ) {
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.lines = lines
        self.capturedAt = capturedAt
    }

    /// One past the last row with text or the cursor, whichever is lower: where "the tail" of the pane ends,
    /// so a pane with blank rows at the bottom still shows its prompt.
    public var contentEnd: Int {
        let lastText = lines.lastIndex { !strippingEscapes($0).trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
        return min(max(rows, lines.count), max(lastText, cursorY) + 1)
    }

    /// Bytes that redraw this snapshot on an empty terminal of the same size.
    /// With `lastRows`, only the bottom rows are drawn (small tiles show the tail of the pane).
    public func ansi(lastRows: Int? = nil) -> [UInt8] {
        var shown = lines
        // capture-pane drops trailing blank lines; pad so "the bottom" means the pane's bottom.
        if shown.count < rows { shown += Array(repeating: "", count: rows - shown.count) }
        var cursorRow = cursorY
        if let lastRows, lastRows < shown.count {
            let end = min(shown.count, contentEnd)
            let start = max(0, end - lastRows)
            shown = Array(shown[start..<end])
            cursorRow -= start
        }
        var text = "\u{1B}[0m\u{1B}[H\u{1B}[2J"
        // Reset attributes at each line start so a colour never bleeds into the next line.
        text += shown.map { "\u{1B}[0m" + $0 }.joined(separator: "\r\n")
        if cursorRow >= 0 && cursorRow < shown.count {
            text += "\u{1B}[\(cursorRow + 1);\(cursorX + 1)H"
        }
        return Array(text.utf8)
    }
}

/// The line's text without SGR and other CSI escape sequences.
func strippingEscapes(_ line: String) -> String {
    line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
}

/// Captures many panes with one tmux invocation per tick.
public enum PaneCapture {
    static let marker = "@@openrig-pane"

    /// One command line: for each pane, a marker line with its geometry, then its screen.
    public static func batchArgs(panes: [String]) -> [String] {
        var args: [String] = []
        for (i, pane) in panes.enumerated() {
            if i > 0 { args.append(";") }
            args += [
                "display-message", "-p", "-t", pane,
                "\(marker) #{pane_id} #{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{?#{==:#{status},off},0,1}",
                ";", "capture-pane", "-p", "-e", "-t", pane,
            ]
        }
        return args
    }

    public static func parse(_ output: String, capturedAt: Date = .now) -> [String: PaneSnapshot] {
        var result: [String: PaneSnapshot] = [:]
        var current: PaneSnapshot?
        func flush() {
            if let snapshot = current { result[snapshot.pane] = snapshot }
        }
        // Each command's output ends with a newline; drop the final one so it doesn't read as a blank row.
        let body = output.hasSuffix("\n") ? output.dropLast() : Substring(output)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker + " ") {
                flush()
                let f = line.split(separator: " ").dropFirst().map(String.init)
                guard f.count >= 5, let cols = Int(f[1]), let rows = Int(f[2]), let x = Int(f[3]), let y = Int(f[4])
                else {
                    current = nil
                    continue
                }
                current = PaneSnapshot(
                    pane: f[0], cols: cols, rows: rows, cursorX: x, cursorY: y, lines: [], capturedAt: capturedAt)
                current?.statusRows = f.count > 5 ? Int(f[5]) ?? 0 : 0
            } else {
                current?.lines.append(String(line))
            }
        }
        flush()
        return result
    }
}

extension Tmux {
    /// Snapshots of the given panes. A pane that no longer exists is left out rather than failing the batch.
    public func snapshots(panes: [String]) async -> [String: PaneSnapshot] {
        guard !panes.isEmpty else { return [:] }
        if let output = try? await run(PaneCapture.batchArgs(panes: panes)) {
            return PaneCapture.parse(output)
        }
        // tmux stops a command list at the first bad target; retry one by one.
        var result: [String: PaneSnapshot] = [:]
        for pane in panes {
            if let output = try? await run(PaneCapture.batchArgs(panes: [pane])) {
                result.merge(PaneCapture.parse(output)) { a, _ in a }
            }
        }
        return result
    }
}

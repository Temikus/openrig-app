import Foundation
import SwiftTerm

/// A live `tmux attach-session` in a pseudo-terminal. Read output with `subscribe`; `send` types into it.
/// Ending it (`close`, or releasing it) detaches the tmux client.
public final class AttachSession: LocalProcessDelegate, @unchecked Sendable {
    public let session: String
    public var onExit: (@Sendable (Int32?) -> Void)?
    /// Grid size reported to tmux. With `ignore-size`, the pane keeps its own size either way.
    public var size: (cols: Int, rows: Int) {
        didSet { resizePTY() }
    }

    private var process: LocalProcess!
    // tmux paints the whole screen once, right after attaching, often before a view subscribes.
    // Keep recent output so a late subscriber still sees the screen.
    private let lock = NSLock()
    private var backlog: [UInt8] = []
    // Several at once: SwiftUI builds a tile's new view before it dismantles the old one.
    private var subscribers: [Int: @Sendable (ArraySlice<UInt8>) -> Void] = [:]
    private var nextToken = 0
    private static let backlogLimit = 256 * 1024

    /// Delivers the backlog, then every later chunk, on the process's queue, until `unsubscribe`.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (ArraySlice<UInt8>) -> Void) -> Int {
        // Replay under the lock so no newer chunk can reach the handler before the backlog does.
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        subscribers[nextToken] = handler
        if !backlog.isEmpty { handler(backlog[...]) }
        return nextToken
    }

    public func unsubscribe(_ token: Int) {
        lock.withLock { _ = subscribers.removeValue(forKey: token) }
    }

    public init(tmux: Tmux, session: String, cols: Int = 80, rows: Int = 24) {
        self.session = session
        self.size = (cols, rows)
        process = LocalProcess(delegate: self)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment.removeValue(forKey: "TMUX")  // never nest inside the app's own tmux, if any
        process.startProcess(
            executable: tmux.executable.path(),
            args: tmux.attachArgs(session: session),
            environment: environment.map { "\($0.key)=\($0.value)" })
    }

    deinit { close() }

    public var isRunning: Bool { process?.running ?? false }

    public func send(_ bytes: ArraySlice<UInt8>) {
        process.send(data: bytes)
    }

    public func close() {
        if process?.running == true { process.terminate() }
    }

    private func resizePTY() {
        var ws = getWindowSize()
        _ = process?.updateWindowSize(&ws)
    }

    // MARK: LocalProcessDelegate

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock()
        backlog.append(contentsOf: slice)
        if backlog.count > Self.backlogLimit { backlog.removeFirst(backlog.count - Self.backlogLimit) }
        let handlers = Array(subscribers.values)
        lock.unlock()
        for handler in handlers { handler(slice) }
    }

    public func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Keeps at most one tmux client attached: the focused tile's. Focusing another seat closes the old
/// client before opening the new one.
@MainActor
public final class FocusedAttach {
    public private(set) var current: AttachSession?
    let tmux: Tmux

    public init(tmux: Tmux) {
        self.tmux = tmux
    }

    @discardableResult
    public func focus(session: String, cols: Int, rows: Int) -> AttachSession {
        if let current, current.session == session, current.isRunning { return current }
        current?.close()
        let next = AttachSession(tmux: tmux, session: session, cols: cols, rows: rows)
        current = next
        return next
    }

    public func release() {
        current?.close()
        current = nil
    }
}

import AppKit
import RigTerminal
import SwiftTerm
import SwiftUI

/// A SwiftTerm view showing either a pane snapshot or the live attached client.
/// The grid is fixed to the pane's size and the font is chosen to fit the tile, so text stays sharp.
struct TerminalSurface: NSViewRepresentable {
    enum Source {
        case snapshot(PaneSnapshot, lastRows: Int?)
        case attached(AttachSession)
    }

    let source: Source
    let cols: Int
    let rows: Int
    let fontSize: CGFloat
    /// Keys and mouse reach tmux only when true (Type mode).
    let interactive: Bool

    static func font(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Largest font size, in half points, whose grid fits `width` (and `height`, when given).
    static func fittingFontSize(
        cols: Int, rows: Int = 0, width: CGFloat, height: CGFloat = .infinity, range: ClosedRange<CGFloat> = 6...13
    ) -> CGFloat {
        let probe = font(100)
        let advance = ("W" as NSString).size(withAttributes: [.font: probe]).width / 100
        let lineHeight = (probe.ascender - probe.descender + probe.leading) / 100
        var size = width / (CGFloat(max(cols, 1)) * advance)
        if rows > 0 { size = min(size, height / (CGFloat(rows) * lineHeight)) }
        size = (size * 2).rounded(.down) / 2
        return min(max(size, range.lowerBound), range.upperBound)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Self.font(fontSize))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
        view.optionAsMetaKey = true
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        let coordinator = context.coordinator
        if view.font.pointSize != fontSize { view.font = Self.font(fontSize) }
        if coordinator.grid.cols != cols || coordinator.grid.rows != rows {
            view.resize(cols: cols, rows: rows)
            coordinator.grid = (cols, rows)
            coordinator.lastFed = []
        }
        view.allowMouseReporting = interactive
        coordinator.interactive = interactive

        switch source {
        case .snapshot(let snap, let lastRows):
            coordinator.bind(nil)
            let bytes = snap.ansi(lastRows: lastRows)
            if bytes != coordinator.lastFed {
                view.feed(byteArray: bytes[...])
                coordinator.lastFed = bytes
            }
        case .attached(let session):
            coordinator.bind(session)
        }

        if interactive, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalView, context: Context) -> CGSize? {
        nsView.getOptimalFrameSize().size
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.bind(nil)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var view: TerminalView?
        var interactive = false
        var lastFed: [UInt8] = []
        var grid = (cols: 0, rows: 0)
        private var session: AttachSession?
        private var token: Int?

        func bind(_ next: AttachSession?) {
            guard next !== session else { return }
            if let token { session?.unsubscribe(token) }
            session = next
            token = nil
            lastFed = []
            guard let next else { return }
            token = next.subscribe { [weak self] slice in
                let bytes = Array(slice)
                DispatchQueue.main.async { self?.view?.feed(byteArray: bytes[...]) }
            }
        }

        // Keys reach tmux only in Type mode; in Message mode the composer (M4) sends with `rig send`.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard interactive else { return }
            session?.send(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

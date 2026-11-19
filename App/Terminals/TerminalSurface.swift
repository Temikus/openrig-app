import AppKit
import RigTerminal
import SwiftTerm
import SwiftUI

/// A SwiftTerm view showing either a pane snapshot or the live attached client.
/// The grid is fixed to the pane's size and the font is chosen to fit the tile, so text stays sharp.
struct TerminalSurface: NSViewRepresentable {
    enum Source {
        /// `transcriptOnly` leaves out Claude Code's input box (see `PaneSnapshot.transcriptEnd`).
        case snapshot(PaneSnapshot, lastRows: Int?, transcriptOnly: Bool = false)
        case attached(AttachSession)
    }

    let source: Source
    let cols: Int
    let rows: Int
    let fontSize: CGFloat
    /// Keys and mouse reach tmux only when true (Type mode).
    let interactive: Bool
    /// Settings › Terminals › Use Option as Meta.
    var optionAsMeta = true
    /// What VoiceOver reads while typing: the pane as plain text, and whose it is.
    var accessibleText = ""
    var accessibleName = ""
    /// Asks tmux to repaint a live client, after a font change cleared the view.
    var onRepaint: (() -> Void)?

    static func font(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Cell width and row height per point of font size, measured once.
    private static let ratios: (advance: CGFloat, line: CGFloat) = {
        let probe = font(100)
        let advance = ("W" as NSString).size(withAttributes: [.font: probe]).width / 100
        return (advance, (probe.ascender - probe.descender + probe.leading) / 100)
    }()

    /// Width of one cell at `size`, snapped to the pixel grid of a `scale` display the way SwiftTerm snaps its cells.
    /// Unsnapped, a wide pane came out wider than counted and lost its right edge.
    static func advance(_ size: CGFloat, scale: CGFloat = 2) -> CGFloat {
        (ratios.advance * size * scale).rounded() / scale
    }

    /// Height of one row at `size`, rounded up to a whole point as SwiftTerm rounds its cells (line spacing 1).
    /// Unrounded, rows came out taller than counted, and the bottom-aligned tile clipped its top row.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        (ratios.line * size).rounded(.up)
    }

    /// Largest font size, in half points, whose grid fits `width` (and `height`, when given).
    static func fittingFontSize(
        cols: Int, rows: Int = 0, width: CGFloat, height: CGFloat = .infinity, scale: CGFloat = 2,
        range: ClosedRange<CGFloat> = 6...13
    ) -> CGFloat {
        let cols = CGFloat(max(cols, 1))
        var size = width / (cols * ratios.advance)
        if rows > 0 { size = min(size, height / (CGFloat(rows) * ratios.line)) }
        size = min(max((size * 2).rounded(.down) / 2, range.lowerBound), range.upperBound)
        // Snapped cells can still overshoot by a fraction: step down until the grid fits.
        while size > range.lowerBound,
            cols * advance(size, scale: scale) > width || CGFloat(rows) * lineHeight(size) > height
        {
            size -= 0.5
        }
        return size
    }

    /// Whether a `cols` × `rows` grid at `size` fits in `width` × `height`.
    static func fits(cols: Int, rows: Int, size: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat) -> Bool {
        CGFloat(cols) * advance(size, scale: scale) <= width && CGFloat(rows) * lineHeight(size) <= height
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TileTerminalView {
        let view = TileTerminalView(frame: .zero, font: Self.font(fontSize))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
        view.optionAsMetaKey = optionAsMeta
        context.coordinator.view = view
        // A view rebuilt for a client that is already attached has none of its screen yet.
        if case .attached = source { DispatchQueue.main.async { onRepaint?() } }
        return view
    }

    func updateNSView(_ view: TileTerminalView, context: Context) {
        let coordinator = context.coordinator
        // A new font makes SwiftTerm refit its grid to the frame and soft-reset, so the grid is set again whenever
        // the font changes, and a live client is asked to repaint what the reset cleared.
        let fontChanged = view.font.pointSize != fontSize
        if fontChanged { view.font = Self.font(fontSize) }
        if fontChanged || coordinator.grid.cols != cols || coordinator.grid.rows != rows {
            view.resize(cols: cols, rows: rows)
            coordinator.grid = (cols, rows)
            coordinator.lastFed = []
            if fontChanged, case .attached = source { onRepaint?() }
        }
        // No mouse reporting: with tmux's mouse on, a scroll would put the shared pane in copy mode for everyone.
        view.allowMouseReporting = false
        view.optionAsMetaKey = optionAsMeta
        // Take the keyboard once, as Type mode starts; afterwards a click elsewhere keeps the keyboard there.
        let startsTyping = interactive && !coordinator.interactive
        coordinator.interactive = interactive
        view.interactive = interactive
        view.accessibleName = accessibleName
        view.accessibleText = accessibleText

        switch source {
        case .snapshot(let snap, let lastRows, let transcriptOnly):
            coordinator.bind(nil)
            let bytes = snap.ansi(lastRows: lastRows, transcriptOnly: transcriptOnly)
            if bytes != coordinator.lastFed {
                view.feed(byteArray: bytes[...])
                coordinator.lastFed = bytes
            }
        case .attached(let session):
            coordinator.bind(session)
        }

        if startsTyping {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TileTerminalView, context: Context) -> CGSize? {
        nsView.getOptimalFrameSize().size
    }

    static func dismantleNSView(_ view: TileTerminalView, coordinator: Coordinator) {
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

/// A tile's terminal. Snapshot tiles stay out of the Tab order and the accessibility tree: they drop every key, and
/// the tile's own button reads their text. While typing, VoiceOver sees a text area holding the pane's text.
/// (SwiftTerm's Mac view exposes no text, and its `acceptsFirstResponder` can't be overridden from here.)
final class TileTerminalView: TerminalView {
    var interactive = false
    var accessibleName = ""
    var accessibleText = "" {
        didSet {
            if interactive, accessibleText != oldValue {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }

    override var canBecomeKeyView: Bool { interactive && super.canBecomeKeyView }
    override func isAccessibilityElement() -> Bool { interactive }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "\(accessibleName)'s terminal" }
    override func accessibilityValue() -> Any? { accessibleText }
}

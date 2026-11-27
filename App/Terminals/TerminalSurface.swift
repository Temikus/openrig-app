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
        /// The pane's scrollback, read-only, drawn at the pane's width.
        case history(PaneHistory)
    }

    let source: Source
    let cols: Int
    let rows: Int
    let fontSize: CGFloat
    /// Keys and mouse reach tmux only when true (Type mode).
    let interactive: Bool
    /// Whether Type mode is still on, read when a leaving view hands the keyboard on (a view on its way out keeps
    /// its last `interactive`).
    var stillTyping: () -> Bool = { false }
    /// Settings › Terminals › Use Option as Meta.
    var optionAsMeta = true
    /// What VoiceOver reads while typing: the pane as plain text, and whose it is.
    var accessibleText = ""
    var accessibleName = ""
    /// Asks tmux to repaint a live client, after a font change cleared the view.
    var onRepaint: (() -> Void)?
    /// A scroll up calls this. Over the live client it replaces SwiftTerm's arrow keys (see `TileTerminalView.route`).
    var onScrollBack: (() -> Void)?
    /// History: a scroll down past the last line calls this.
    var onScrolledToEnd: (() -> Void)?

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
        // Take the keyboard as Type mode starts; afterwards a click elsewhere keeps the keyboard there.
        let startsTyping = interactive && !coordinator.interactive
        coordinator.interactive = interactive
        view.interactive = interactive
        view.stillTyping = stillTyping
        view.accessibleName = accessibleName
        view.accessibleText = accessibleText
        view.onScrollBack = onScrollBack
        view.onScrolledToEnd = onScrolledToEnd
        // Only the typing tile takes the wheel; the others leave it to the grid.
        let takesWheel = onScrollBack != nil || onScrolledToEnd != nil
        if takesWheel, coordinator.wheelMonitor == nil {
            coordinator.wheelMonitor = view.monitorWheel()
        } else if !takesWheel, let monitor = coordinator.wheelMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.wheelMonitor = nil
        }

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
        case .history(let history):
            coordinator.bind(nil)
            let bytes = history.ansi()
            if bytes != coordinator.lastFed {
                let first = coordinator.lastFed.isEmpty
                view.changeScrollback(history.lines.count + rows)
                view.feed(byteArray: bytes[...])
                coordinator.lastFed = bytes
                // The bottom matches the live screen; start a little above it so the scroll shows.
                if first { view.scrollUp(lines: 3) }
            }
        }

        if startsTyping { view.takeKeyboard() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TileTerminalView, context: Context) -> CGSize? {
        nsView.getOptimalFrameSize().size
    }

    static func dismantleNSView(_ view: TileTerminalView, coordinator: Coordinator) {
        coordinator.bind(nil)
        if let monitor = coordinator.wheelMonitor { NSEvent.removeMonitor(monitor) }
        coordinator.wheelMonitor = nil
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var view: TerminalView?
        var interactive = false
        var lastFed: [UInt8] = []
        var grid = (cols: 0, rows: 0)
        var wheelMonitor: Any?
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

    var onScrollBack: (() -> Void)?
    var onScrolledToEnd: (() -> Void)?
    /// A trackpad gesture began at the last line: only then does scrolling on down leave the history.
    private var gestureBeganAtEnd = false

    override var canBecomeKeyView: Bool { interactive && super.canBecomeKeyView }

    /// Set by the surface: whether Type mode is on now, unlike `interactive`, which a view fading out keeps.
    var stillTyping: () -> Bool = { false }

    /// Type mode asked for the keyboard before the view was in a window.
    private var wantsKeyboard = false

    /// Makes this the window's first responder, now or once the view is in a window.
    func takeKeyboard() {
        wantsKeyboard = true
        // Next turn: the view is usually not in a window yet while SwiftUI updates it.
        DispatchQueue.main.async { [weak self] in self?.claim() }
    }

    private func claim() {
        guard wantsKeyboard else { return }
        guard interactive else {
            wantsKeyboard = false
            return
        }
        guard let window else { return }
        wantsKeyboard = false
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claim()
    }

    /// Hazard: as Type mode starts, SwiftUI builds a second, short-lived interactive view for the typing tile, kept
    /// until the crossfade ends. Both take the keyboard; the copy took it last, and when it left, the window kept the
    /// keyboard and every key beeped. So a view that leaves with the keyboard hands it to the typing view still
    /// there, unless something else took it meanwhile.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.firstResponder === window,
                    let next = window.contentView.flatMap(Self.typingView), next.stillTyping()
                else { return }
                window.makeFirstResponder(next)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Type mode ended: any terminal view holding the keyboard gives it to its window.
    static func releaseKeyboard() {
        for window in NSApp.windows where window.firstResponder is TileTerminalView {
            window.makeFirstResponder(nil)
        }
    }

    /// The interactive terminal view under `view`, if any.
    private static func typingView(in view: NSView) -> TileTerminalView? {
        if let terminal = view as? TileTerminalView, terminal.interactive { return terminal }
        for sub in view.subviews {
            if let found = typingView(in: sub) { return found }
        }
        return nil
    }

    /// Takes wheel events over this view before SwiftTerm does. SwiftTerm's `scrollWheel` isn't open, so this is
    /// a local monitor; it is removed when SwiftUI dismantles the view.
    func monitorWheel() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window, event.window === window, let content = window.contentView,
                visibleRect.contains(convert(event.locationInWindow, from: nil)),
                let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                // SwiftUI drawn over this view (a tile's click layer) hit-tests to an ancestor; another NSView on top
                // keeps the wheel.
                hit.isDescendant(of: self) || isDescendant(of: hit)
            else { return event }
            return self.route(event) ? nil : event
        }
    }

    /// Whether the wheel event was handled here. The live client is a tmux client on SwiftTerm's alternate
    /// screen; without mouse reporting, SwiftTerm turns the wheel into Up and Down keys there, which Claude Code
    /// reads as its input history.
    private func route(_ event: NSEvent) -> Bool {
        if let onScrollBack {
            if event.scrollingDeltaY > 0 {
                onScrollBack()
                return true
            }
            // A snapshot lets the grid scroll down; the live client would send Down keys.
            return interactive
        }
        guard let onScrolledToEnd else { return false }
        let atEnd = scrollPosition >= 1 || !canScroll
        if event.phase == .began { gestureBeganAtEnd = atEnd }
        // Momentum after a flick to the bottom stops there rather than leaving.
        if event.scrollingDeltaY < 0, atEnd, event.momentumPhase.isEmpty, event.phase.isEmpty || gestureBeganAtEnd {
            onScrolledToEnd()
        } else {
            // Message mode lays the tile's click layer over this view, so AppKit would send the wheel to the grid.
            scrollWheel(with: event)
        }
        return true
    }
    override func isAccessibilityElement() -> Bool { interactive }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "\(accessibleName)'s terminal" }
    override func accessibilityValue() -> Any? { accessibleText }
}

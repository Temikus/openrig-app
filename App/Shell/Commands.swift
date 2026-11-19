import SwiftUI

/// What the menu bar can do in the frontmost main window; each view publishes its part as a focused scene value.
struct WindowActions {
    var queueTask: (() -> Void)?
    var needsYou: () -> Void
}

struct CanvasZoomActions {
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fit: () -> Void
}

/// The Terminals view's keys. Its key monitor sees ⌘] ⌘[ ⌘T first; these items make them findable and clickable.
struct TerminalActions {
    var next: () -> Void
    var previous: () -> Void
    /// Nil when no tile has focus.
    var toggleTyping: (() -> Void)?
    var typing: Bool
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
    @Entry var canvasZoom: CanvasZoomActions?
    @Entry var terminalActions: TerminalActions?
}

struct OpenRigCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.windowActions) private var window
    @FocusedValue(\.canvasZoom) private var zoom
    @FocusedValue(\.terminalActions) private var terminal

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        // ⌘N queues a task, as the toolbar says; a second window is the rarer need.
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: OpenRigApp.mainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Rig") {
            Button("Queue Task…") { window?.queueTask?() }
                .keyboardShortcut("n")
                .disabled(window?.queueTask == nil)
            Button("Needs You…") { window?.needsYou() }
                .keyboardShortcut("j")
                .disabled(window == nil)
            Divider()
            Button("Refresh") { Task { await store.refreshNow() } }
                .keyboardShortcut("r")
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { store.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Zoom In") { zoom?.zoomIn() }
                .keyboardShortcut("=")
                .disabled(zoom == nil)
            Button("Zoom Out") { zoom?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(zoom == nil)
            Button("Zoom to Fit") { zoom?.fit() }
                .keyboardShortcut("0")
                .disabled(zoom == nil)
            Divider()
            Button("Next Tile") { terminal?.next() }
                .keyboardShortcut("]")
                .disabled(terminal == nil)
            Button("Previous Tile") { terminal?.previous() }
                .keyboardShortcut("[")
                .disabled(terminal == nil)
            Button(terminal?.typing == true ? "Stop Typing" : "Type into Terminal") { terminal?.toggleTyping?() }
                .keyboardShortcut("t")
                .disabled(terminal?.toggleTyping == nil)
            Divider()
            Button("Search Queue") {
                store.viewMode = .queue
                store.wantsSearch = true
            }
            .keyboardShortcut("f")
            // With no rig there's no board to focus, and the request would linger for a later visit.
            .disabled(store.rig == nil)
            Divider()
        }
    }
}

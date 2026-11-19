/// Keys the Terminals view handles itself. There is no key for Allow once: a stray key must not approve.
public enum TerminalKey: Sendable {
    case escape
    /// ⌘] and ⌘[.
    case nextTile, previousTile
    /// ⌘T.
    case toggleTyping
}

public struct TerminalKeyContext: Sendable {
    /// False when the key reached a popover or sheet: those are their own windows, and Esc there closes them.
    public var inMainWindow: Bool
    public var focused: Bool
    public var typing: Bool
    /// A text field has the keyboard (a composer draft); Esc belongs to it.
    public var editingText: Bool
    /// Settings › Terminals: Esc while typing reaches the agent (it interrupts a turn), and only ⌘T stops typing.
    public var escGoesToPane: Bool

    public init(inMainWindow: Bool, focused: Bool, typing: Bool, editingText: Bool, escGoesToPane: Bool = false) {
        self.inMainWindow = inMainWindow
        self.focused = focused
        self.typing = typing
        self.editingText = editingText
        self.escGoesToPane = escGoesToPane
    }
}

public enum TerminalKeyAction: Equatable, Sendable {
    case passThrough
    case stopTyping
    case releaseFocus
    case moveFocus(Int)
    case toggleTyping
}

/// Esc leaves Type mode first (so a stray Esc never reaches the agent mid-turn), then releases focus.
public func terminalKeyAction(_ key: TerminalKey, _ context: TerminalKeyContext) -> TerminalKeyAction {
    guard context.inMainWindow else { return .passThrough }
    switch key {
    case .escape:
        if context.typing { return context.escGoesToPane ? .passThrough : .stopTyping }
        return context.focused && !context.editingText ? .releaseFocus : .passThrough
    case .nextTile: return .moveFocus(1)
    case .previousTile: return .moveFocus(-1)
    case .toggleTyping: return context.focused ? .toggleTyping : .passThrough
    }
}

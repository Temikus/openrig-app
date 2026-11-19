import Testing

@testable import RigDomain

@Suite struct TerminalKeysTests {
    let esc = TerminalKey.escape

    @Test func escLeavesTypeModeThenReleasesFocus() {
        let typing = TerminalKeyContext(inMainWindow: true, focused: true, typing: true, editingText: false)
        #expect(terminalKeyAction(esc, typing) == .stopTyping)
        let watching = TerminalKeyContext(inMainWindow: true, focused: true, typing: false, editingText: false)
        #expect(terminalKeyAction(esc, watching) == .releaseFocus)
        let idle = TerminalKeyContext(inMainWindow: true, focused: false, typing: false, editingText: false)
        #expect(terminalKeyAction(esc, idle) == .passThrough)
    }

    /// Settings › Terminals › Esc while typing › Goes to the pane: Esc reaches the agent, and ⌘T is the way out.
    @Test func escCanGoToThePaneWhileTyping() {
        var typing = TerminalKeyContext(inMainWindow: true, focused: true, typing: true, editingText: false)
        typing.escGoesToPane = true
        #expect(terminalKeyAction(esc, typing) == .passThrough)
        #expect(terminalKeyAction(.toggleTyping, typing) == .toggleTyping)
        var watching = typing
        watching.typing = false
        #expect(terminalKeyAction(esc, watching) == .releaseFocus, "outside Type mode Esc still releases focus")
    }

    @Test func escInATextFieldStaysWithTheField() {
        let drafting = TerminalKeyContext(inMainWindow: true, focused: true, typing: false, editingText: true)
        #expect(terminalKeyAction(esc, drafting) == .passThrough)
    }

    /// A popover (Needs you, Queue task) or a sheet is its own window: Esc there closes it, so it is never taken.
    @Test func keysInOtherWindowsPassThrough() {
        let popover = TerminalKeyContext(inMainWindow: false, focused: true, typing: true, editingText: false)
        for key in [TerminalKey.escape, .nextTile, .previousTile, .toggleTyping] {
            #expect(terminalKeyAction(key, popover) == .passThrough)
        }
    }

    @Test func focusKeys() {
        let any = TerminalKeyContext(inMainWindow: true, focused: false, typing: false, editingText: false)
        #expect(terminalKeyAction(.nextTile, any) == .moveFocus(1))
        #expect(terminalKeyAction(.previousTile, any) == .moveFocus(-1))
        #expect(terminalKeyAction(.toggleTyping, any) == .passThrough, "nothing focused to type into")
        var focused = any
        focused.focused = true
        #expect(terminalKeyAction(.toggleTyping, focused) == .toggleTyping)
    }
}

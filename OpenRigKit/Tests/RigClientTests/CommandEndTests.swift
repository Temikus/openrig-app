import Testing

@testable import RigClient

/// Allow once waits until the command's end has been on screen. The area under the pinned buttons doesn't count:
/// content scrolls under them, and the person can't read it there. Numbers from a capture: an 874 pt screen with a
/// 116 pt navigation bar and a 160 pt button bar leaves 598 pt between them.
@Suite struct CommandEndTests {
    let top = 116.0
    let between = 598.0

    @Test func anEndAboveTheBarIsSeen() {
        #expect(CommandEnd.isSeen(endY: 148, offsetY: -top, topInset: top, visibleHeight: between))
        #expect(CommandEnd.isSeen(endY: 598, offsetY: -top, topInset: top, visibleHeight: between))
    }

    @Test func anEndUnderTheBarIsNotSeen() {
        #expect(!CommandEnd.isSeen(endY: 610.33, offsetY: -top, topInset: top, visibleHeight: between))
        #expect(!CommandEnd.isSeen(endY: 750, offsetY: -top, topInset: top, visibleHeight: between))
    }

    @Test func scrollingTheEndAboveTheBarMakesItSeen() {
        #expect(!CommandEnd.isSeen(endY: 1200, offsetY: 400, topInset: top, visibleHeight: between))
        #expect(CommandEnd.isSeen(endY: 1200, offsetY: 486, topInset: top, visibleHeight: between))
    }

    /// Before the insets are applied, SwiftUI reports offset 0 and no insets with the same height: same answer.
    @Test func theFirstReportBeforeInsetsGivesTheSameAnswer() {
        #expect(!CommandEnd.isSeen(endY: 610.33, offsetY: 0, topInset: 0, visibleHeight: between))
        #expect(CommandEnd.isSeen(endY: 568.33, offsetY: 0, topInset: 0, visibleHeight: between))
    }
}

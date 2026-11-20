import Testing

@testable import RigDomain

@Suite struct BoardMoveTests {
    let columns: [[String]] = [["a", "b", "c"], [], ["d"], ["e", "f"]]

    @Test func startsAtTheFirstCardWithNothingSelected() {
        #expect(boardMove(columns, from: nil, .down) == "a")
        #expect(boardMove(columns, from: "gone", .right) == "a")
        #expect(boardMove([[String]]([[], []]), from: nil, .down) == nil)
    }

    @Test func upAndDownStayInTheColumn() {
        #expect(boardMove(columns, from: "a", .down) == "b")
        #expect(boardMove(columns, from: "c", .down) == "c")
        #expect(boardMove(columns, from: "a", .up) == "a")
    }

    /// Sideways skips empty columns and keeps the row where it can.
    @Test func leftAndRightSkipEmptyColumns() {
        #expect(boardMove(columns, from: "c", .right) == "d")
        #expect(boardMove(columns, from: "d", .left) == "a")
        #expect(boardMove(columns, from: "b", .right) == "d")
        #expect(boardMove(columns, from: "d", .right) == "e")
        #expect(boardMove(columns, from: "f", .right) == "f")
        #expect(boardMove(columns, from: "f", .left) == "d")
    }
}

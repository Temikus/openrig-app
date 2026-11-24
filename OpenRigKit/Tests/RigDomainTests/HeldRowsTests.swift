import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite struct HeldRowsTests {
    @Test func openRowsAreReplacedOnEachRead() {
        var rows = HeldRows()
        rows.replaceOpen([item("a"), item("b")])
        rows.replaceOpen([item("b"), item("c")])
        #expect(rows.all.map(\.id).sorted() == ["b", "c"])
        #expect(!rows.holds("a"))
    }

    @Test func allIsNewestCreatedFirstAndEachRowOnce() {
        var rows = HeldRows()
        rows.replaceOpen([item("a", created: 10), item("b", created: 30)])
        rows.replaceClosed([item("c", .done, created: 20)], since: at(0))
        rows.keep(item("b", created: 30))
        #expect(rows.all.map(\.id) == ["b", "c", "a"])
    }

    @Test func theNewerCopyWins() {
        var rows = HeldRows()
        rows.replaceOpen([item("a", .inProgress, updated: 10)])
        rows.keep(item("a", .done, updated: 20))
        #expect(rows.row("a")?.state == .done)
        #expect(rows.all.map(\.state) == [.done])
    }

    @Test func onATieOpenBeatsByIDBeatsClosed() {
        var rows = HeldRows()
        rows.replaceClosed([item("a", .done, updated: 10, closureReason: "closed")], since: at(0))
        rows.keep(item("a", .done, updated: 10, closureReason: "by id"))
        #expect(rows.row("a")?.closureReason == "by id")
        rows.replaceOpen([item("a", .inProgress, updated: 10)])
        #expect(rows.row("a")?.state == .inProgress)
    }

    @Test func rowsReadByIDOutliveOpenReads() {
        var rows = HeldRows()
        rows.keep(item("old", .done))
        rows.replaceOpen([])
        rows.dropClosed()
        #expect(rows.holds("old"))
    }

    @Test func closedRowsAreToppedUpAndDropped() {
        var rows = HeldRows()
        #expect(rows.topUpSince == nil)
        rows.topUpClosed([item("ignored", .done)])
        #expect(!rows.holds("ignored"))

        rows.replaceClosed([item("a", .done, updated: 110)], since: at(100))
        #expect(rows.topUpSince == at(110))
        rows.topUpClosed([item("a", .done, updated: 110, closureReason: "again"), item("b", .done, updated: 150)])
        #expect(rows.row("a")?.closureReason == "again")
        #expect(rows.topUpSince == at(150))

        rows.dropClosed()
        #expect(rows.all.isEmpty)
        #expect(rows.topUpSince == nil)
    }

    @Test func topUpStartsAtTheWindowWhenNothingClosedYet() {
        var rows = HeldRows()
        rows.replaceClosed([], since: at(100))
        #expect(rows.topUpSince == at(100))
    }

    @Test func missingAncestorsComeFromTheChainOfRecord() {
        var rows = HeldRows()
        rows.replaceOpen([item("c", after: "b", chain: ["a", "b"])])
        #expect(rows.missingAncestors(of: "c") == ["a", "b"])
        rows.keep(item("b", .handedOff))
        #expect(rows.missingAncestors(of: "c") == ["a"])
        #expect(rows.missingAncestors(of: "unknown") == [])
    }

    /// Rows created before `chainOfRecord` existed name only their direct predecessor.
    @Test func aPredecessorOutsideTheChainCounts() {
        var rows = HeldRows()
        rows.replaceOpen([item("c", after: "b")])
        #expect(rows.missingAncestors(of: "c") == ["b"])
    }

    @Test func recordedRowsSplitIntoOpenAndClosed() throws {
        let recorded: [QItem] = try RigFixtures.decode("queue-denkeeper")
        let open = recorded.filter { workStatus($0).isActive }
        var rows = HeldRows()
        rows.replaceOpen(open)
        rows.replaceClosed(recorded.filter { !workStatus($0).isActive }, since: .distantPast)
        #expect(Set(rows.all.map(\.id)) == Set(recorded.map(\.id)))
        #expect(rows.all.count == recorded.count)
    }
}

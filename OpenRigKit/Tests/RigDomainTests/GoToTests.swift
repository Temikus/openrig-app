import RigModel
import Testing

@testable import RigDomain

@Suite struct GoToTests {
    let items: [GoToItem] = [
        GoToItem(kind: .rig, id: "r1", title: "denkeeper", detail: "7 seats"),
        GoToItem(kind: .rig, id: "r2", title: "kernel", detail: "4 seats"),
        GoToItem(kind: .seat, id: "s1", title: "review-design", detail: "denkeeper"),
        GoToItem(kind: .seat, id: "s2", title: "review-security", detail: "denkeeper"),
        GoToItem(kind: .seat, id: "s3", title: "dev-b1", detail: "denkeeper"),
        GoToItem(kind: .task, id: "t1", title: "q-d439", detail: "Pick ready issues and review them"),
    ]

    @Test func anEmptyQueryListsEverythingInOrder() {
        #expect(goToMatches("", in: items).map(\.id) == ["r1", "r2", "s1", "s2", "s3", "t1"])
        #expect(goToMatches("  ", in: items, limit: 2).map(\.id) == ["r1", "r2"])
    }

    @Test func prefixBeatsWordStartBeatsSubstring() {
        // "rev": two title prefixes, then the task whose summary has "review".
        #expect(goToMatches("rev", in: items).map(\.id) == ["s1", "s2", "t1"])
        // "sec" starts the word "security" inside "review-security".
        #expect(goToMatches("sec", in: items).map(\.id) == ["s2"])
        // "b1" is inside "dev-b1" at a word start.
        #expect(goToMatches("b1", in: items).map(\.id) == ["s3"])
    }

    @Test func matchesIgnoreCaseAndFindTasksByIdOrSummary() {
        #expect(goToMatches("KERN", in: items).map(\.id) == ["r2"])
        #expect(goToMatches("d439", in: items).map(\.id) == ["t1"])
        #expect(goToMatches("issues", in: items).map(\.id) == ["t1"])
        #expect(goToMatches("zzz", in: items).isEmpty)
    }

    @Test func aClosedTaskLeadsWithItsOutcome() {
        let open = GoToItem(task: item("qitem-1", .inProgress))
        #expect(open.detail == "summary qitem-1")
        #expect(!open.isClosed)
        let done = GoToItem(task: item("qitem-2", .done, closureReason: "no-follow-on"))
        #expect(done.detail == "Done · summary qitem-2")
        #expect(done.isClosed)
        #expect(GoToItem(task: item("qitem-3", .handedOff)).detail.hasPrefix("Handed off · "))
    }

    /// A task that didn't get done doesn't wear a check in the palette.
    @Test func onlyDeniedFailedAndCanceledTasksEndedBadly() {
        let bad = [
            item("d", .denied), item("f", .failed), item("c", .canceled),
            item("dr", .done, closureReason: "denied"),
        ]
        #expect(bad.map { GoToItem(task: $0).endedBadly } == [true, true, true, true])
        let fine = [
            item("o", .inProgress), item("n", .done, closureReason: "no-follow-on"), item("h", .handedOff),
            item("s", .done, closureReason: "superseded"),
        ]
        #expect(fine.map { GoToItem(task: $0).endedBadly } == [false, false, false, false])
    }

    /// Today's closed rows arrive after the palette opens and land among the open ones.
    @Test func theHighlightStaysOnItsRow() {
        let before = goToMatches("", in: items)
        let id = before[goToHighlight("s2", in: before)].id
        #expect(id == "s2")
        let closed = GoToItem(kind: .task, id: "t0", title: "q-0000", detail: "closed")
        let arrived = [items[0], closed] + items.dropFirst()
        let after = goToMatches("", in: arrived)
        #expect(after[goToHighlight(id, in: after)].id == "s2")
        #expect(goToHighlight("gone", in: after) == 0)
        #expect(goToHighlight(nil, in: after) == 0)
    }
}

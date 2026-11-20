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
}

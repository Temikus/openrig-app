import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

func item(
    _ id: String, _ state: QItemState = .inProgress, from: String = "a@r", to: String = "b@r",
    after: String? = nil, created: TimeInterval = 0, updated: TimeInterval? = nil, blockedOn: String? = nil,
    closureReason: String? = nil, closureTarget: String? = nil, closeBy: Date? = nil, chain: [String]? = nil
) -> QItem {
    QItem(
        id: id, source: from, destination: to, state: state, summary: "summary \(id)", blockedOn: blockedOn,
        handedOffFrom: after, closureReason: closureReason, closureTarget: closureTarget, closeBy: closeBy,
        created: Date(timeIntervalSince1970: created), updated: Date(timeIntervalSince1970: updated ?? created),
        chainOfRecord: chain)
}

@Suite struct StatusTests {
    @Test func bothHandoffEncodingsNormalise() {
        let explicit = item("x", .handedOff, closureReason: "handed_off_to", closureTarget: "c@r")
        let viaDone = item("y", .done, closureReason: "handed_off_to", closureTarget: "c@r")
        #expect(workStatus(explicit) == .handedOff(to: "c@r"))
        #expect(workStatus(viaDone) == .handedOff(to: "c@r"))
        #expect(!workStatus(viaDone).isActive)
    }

    /// Aborting a workflow cancels its open packets (seen live).
    @Test func canceledIsClosed() {
        let row = item("x", QItemState(rawValue: "canceled"))
        #expect(workStatus(row) == .closed(reason: "canceled"))
        #expect(!workStatus(row).isActive)
    }

    @Test func recordedRowsCoverBothEncodings() throws {
        let rows: [QItem] = try RigFixtures.decode("queue-denkeeper")
        let handed = rows.filter { if case .handedOff = workStatus($0) { true } else { false } }
        #expect(Set(handed.map(\.state)) == [.handedOff, .done])
    }

    @Test func blockers() {
        #expect(workStatus(item("x", .blocked, blockedOn: "qitem-1")) == .blocked(on: .qitem("qitem-1")))
        let external = workStatus(item("y", .blocked, blockedOn: "external:person-decision-pr602"))
        #expect(external == .blocked(on: .outside("external:person-decision-pr602")))
        #expect(external.needsYou)
        #expect(!workStatus(item("z", .blocked, blockedOn: "qitem-1")).needsYou)
        // A person's session is outside, though it has no "external:" prefix.
        #expect(Blocker(ref: "artem@external") == .outside("artem@external"))
        // Another agent settles a row held on its seat; the person's own addresses still need them.
        #expect(Blocker(ref: "dev-qa@openrig-app") == .seat("dev-qa@openrig-app"))
        #expect(Blocker(ref: "human@kernel") == .outside("human@kernel"), "kernel is also a rig's name")
        #expect(Blocker(ref: "human-sam@host") == .outside("human-sam@host"))
        #expect(!workStatus(item("x", .blocked, blockedOn: "dev-qa@openrig-app")).needsYou)
    }

    @Test func closedAndUnknown() {
        #expect(workStatus(item("x", .done, closureReason: "no-follow-on")) == .closed(reason: "no-follow-on"))
        #expect(workStatus(item("y", QItemState(rawValue: "parked"))) == .unknown("parked"))
        #expect(workStatus(item("y", QItemState(rawValue: "parked"))).isActive, "unknown states stay visible")
    }

    /// The daemon's own active set is pending, in-progress and blocked; `denied` and `failed` are terminal.
    @Test func deniedAndFailedAreClosed() {
        #expect(workStatus(item("d", .denied)) == .closed(reason: "denied"))
        #expect(workStatus(item("f", .failed, closureReason: "no-follow-on")) == .closed(reason: "no-follow-on"))
        var asked = item("d", .denied, updated: 10)
        asked.asksHuman = true
        let rows = [
            asked,
            item("f", .failed, from: "a@r", to: "b@r", updated: 10),
            item("live", .pending, from: "a@r", to: "b@r", updated: 10),
        ]
        #expect(needsYou(rows).isEmpty)
        #expect(seatQueue(for: "b@r", in: rows).owned.map(\.id) == ["live"])
        #expect(!isOverdue(item("f", .failed, closeBy: .distantPast), now: .now))

        let now = Date(timeIntervalSince1970: 10)
        let active = board(rows, filter: BoardFilter(scope: .active), now: now)
        #expect(active.all.map(\.id) == ["live"])
        let today = board(rows, filter: BoardFilter(scope: .today), now: now)
        #expect(Set(today.closed.map(\.id)) == ["d", "f"])
        #expect(today.inProgress.isEmpty)
    }
}

@Suite struct ChainTests {
    @Test func recordedLongChainMatchesChainOfRecord() throws {
        let rows: [QItem] = try RigFixtures.decode("queue-denkeeper")
        let tail = try #require(rows.max { ($0.chainOfRecord?.count ?? 0) < ($1.chainOfRecord?.count ?? 0) })
        let record = try #require(tail.chainOfRecord)
        let chain = ChainIndex(rows).chain(for: tail.id)
        #expect(Array(chain.ids.prefix(chain.focusIndex)) == record)
        #expect(chain.ids[chain.focusIndex] == tail.id)
    }

    @Test func walksForwardFromTheRoot() throws {
        let rows: [QItem] = try RigFixtures.decode("queue-denkeeper")
        let tail = try #require(rows.max { ($0.chainOfRecord?.count ?? 0) < ($1.chainOfRecord?.count ?? 0) })
        let root = try #require(tail.chainOfRecord?.first)
        let chain = ChainIndex(rows).chain(for: root)
        #expect(chain.focusIndex == 0)
        #expect(chain.ids.contains(tail.id))
    }

    @Test func ancestorsOutsideTheWindowComeFromChainOfRecord() {
        // Only c and d are loaded; a and b fell outside the list limit.
        let rows = [item("c", .done, after: "b", chain: ["a", "b"]), item("d", after: "c", chain: ["a", "b", "c"])]
        let chain = ChainIndex(rows).chain(for: "d")
        #expect(chain.ids == ["a", "b", "c", "d"])
        #expect(chain.links[0] == .missing("a"))
        #expect(chain.links[1] == .missing("b"))
        #expect(chain.focusIndex == 3)
    }

    @Test func branchFollowsTheEarliestSuccessor() {
        let rows = [
            item("a", .done), item("b2", after: "a", created: 20), item("b1", after: "a", created: 10),
            item("c", after: "b1", created: 30),
        ]
        let chain = ChainIndex(rows).chain(for: "a")
        #expect(chain.ids == ["a", "b1", "c"])
        #expect(chain.branchCount == 1)
    }

    @Test func cyclesTerminate() {
        let rows = [item("a", after: "b"), item("b", after: "a")]
        let chain = ChainIndex(rows).chain(for: "a")
        #expect(Set(chain.ids) == ["a", "b"])
    }

    @Test func unknownIdIsJustItself() {
        let chain = ChainIndex([]).chain(for: "zz")
        #expect(chain.links == [.missing("zz")])
    }
}

@Suite struct SelectionRuleTests {
    let rows = [
        item("owned", .inProgress, from: "lead@r", to: "b1@r", updated: 10),
        item("asks", .blocked, from: "lead@r", to: "b1@r", updated: 5, blockedOn: "external:human"),
        item("deleg", .pending, from: "b1@r", to: "rev@r", updated: 20),
        item("old", .done, from: "lead@r", to: "b1@r", updated: 30, closureReason: "no-follow-on"),
        item("other", .inProgress, from: "lead@r", to: "rev@r", updated: 1),
    ]

    @Test func seatQueueGroups() {
        let q = seatQueue(for: "b1@r", in: rows)
        #expect(q.needsYou.map(\.id) == ["asks"])
        #expect(q.owned.map(\.id) == ["owned"])
        #expect(q.delegated.map(\.id) == ["deleg"])
    }

    @Test func keepsCurrentWhenItInvolvesTheSeat() {
        #expect(qitemSelection(afterSelecting: "rev@r", current: "deleg", in: rows) == "deleg")
    }

    @Test func otherwisePrefersNeedsYouThenOwnedThenDelegated() {
        #expect(qitemSelection(afterSelecting: "b1@r", current: "other", in: rows) == "asks")
        #expect(qitemSelection(afterSelecting: "rev@r", current: nil, in: rows) == "deleg")
        let noAsks = rows.filter { $0.id != "asks" }
        #expect(qitemSelection(afterSelecting: "b1@r", current: nil, in: noAsks) == "owned")
        #expect(qitemSelection(afterSelecting: "nobody@r", current: "other", in: rows) == nil)
    }
}

@Suite struct BoardTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }

    var rows: [QItem] {
        [
            item("p", .pending, updated: 1_799_999_000),
            item("w", .inProgress, from: "x@r", to: "y@r", updated: 1_700_000_000, closeBy: now - 60),
            item("bl", .blocked, updated: 1_799_990_000, blockedOn: "qitem-p"),
            item("dt", .done, updated: 1_799_999_500, closureReason: "no-follow-on"),
            item("dy", .done, updated: 1_799_000_000, closureReason: "no-follow-on"),
            item("ho", .handedOff, updated: 1_799_999_900, closureReason: "handed_off_to", closureTarget: "y@r"),
        ]
    }

    @Test func activeHidesClosedWork() {
        let b = board(rows, filter: BoardFilter(scope: .active), now: now, calendar: calendar)
        #expect(b.pending.map(\.id) == ["p"])
        #expect(b.inProgress.map(\.id) == ["w"])
        #expect(b.blocked.map(\.id) == ["bl"])
        #expect(b.closed.isEmpty && b.handedOff.isEmpty)
    }

    @Test func todayAddsWorkClosedToday() {
        let b = board(rows, filter: BoardFilter(scope: .today), now: now, calendar: calendar)
        #expect(b.closed.map(\.id) == ["dt"])
        #expect(b.handedOff.map(\.id) == ["ho"])
        #expect(b.inProgress.map(\.id) == ["w"], "active work shows whatever its age")
    }

    @Test func seatOverdueAndSearchFilters() {
        let seat = board(rows, filter: BoardFilter(scope: .active, seat: "y@r"), now: now, calendar: calendar)
        #expect(seat.inProgress.map(\.id) == ["w"] && seat.pending.isEmpty)
        let overdue = board(rows, filter: BoardFilter(scope: .active, overdueOnly: true), now: now, calendar: calendar)
        #expect(overdue.all.map(\.id) == ["w"])
        let search = board(rows, filter: BoardFilter(scope: .today, search: "SUMMARY B"), now: now, calendar: calendar)
        #expect(search.all.map(\.id) == ["bl"])
        let short = board(rows, filter: BoardFilter(scope: .active, search: "q-w"), now: now, calendar: calendar)
        #expect(short.all.map(\.id) == ["w"], "matches the short id shown on cards")
    }

    @Test func overdue() {
        #expect(isOverdue(item("w", closeBy: now - 1), now: now))
        #expect(!isOverdue(item("w", closeBy: now + 1), now: now))
        #expect(!isOverdue(item("d", .done, closeBy: now - 1), now: now), "closed work is never overdue")
    }

    @Test func needsYouIsActiveOutsideBlocks() {
        let extra = rows + [item("h", .blocked, blockedOn: "external:person"), item("hd", .done, blockedOn: "x")]
        #expect(needsYou(extra).map(\.id) == ["h"])
    }
}

import Foundation
import RigModel
import Testing

@testable import RigDomain

@Suite struct NoticesTests {
    let me = "human@host"
    let all = Set(NoticeKind.allCases)

    func prompt(_ session: String, _ command: String, at seconds: TimeInterval = 0) -> PromptInstance {
        let seat = Seat(id: "seat-\(session)", logicalId: "x", sessionName: session)
        let stop = PermissionStop(
            state: .requestObserved, command: command, observedAt: Date(timeIntervalSince1970: seconds), actor: "main")
        return PromptInstance(seat: seat, stop: stop)!
    }

    @Test func firstUpdateOnlyPrimes() {
        var tracker = NoticeTracker()
        let current = notices(entries: [.prompt(prompt("dev@r", "ls"), linked: nil)], rig: "r", me: me)
        #expect(tracker.update(current, enabled: all).isEmpty, "launching the app mustn't replay what's waiting")
    }

    @Test func eachPromptPostsOnce() {
        var tracker = NoticeTracker()
        _ = tracker.update([], enabled: all)
        let current = notices(entries: [.prompt(prompt("dev@r", "npx playwright test"), linked: nil)], rig: "r", me: me)
        let posted = tracker.update(current, enabled: all)
        #expect(posted.map(\.kind) == [.permission])
        #expect(posted.first?.title == "dev needs permission")
        #expect(posted.first?.body == "Wants to run \"npx playwright test\" in r.")
        #expect(posted.first?.target == .seat(rig: "r", session: "dev@r"))
        #expect(tracker.update(current, enabled: all).isEmpty, "a refresh doesn't repost")
    }

    @Test func aNewPromptOnTheSameSeatPostsAgain() {
        var tracker = NoticeTracker()
        _ = tracker.update([], enabled: all)
        _ = tracker.update(
            notices(entries: [.prompt(prompt("dev@r", "ls", at: 1), linked: nil)], rig: "r", me: me), enabled: all)
        let next = notices(entries: [.prompt(prompt("dev@r", "rm -rf build", at: 2), linked: nil)], rig: "r", me: me)
        #expect(tracker.update(next, enabled: all).count == 1)
    }

    @Test func somethingThatLeavesAndComesBackPostsAgain() {
        var tracker = NoticeTracker()
        _ = tracker.update([], enabled: all)
        let ask = notices(entries: [.qitem(item("q1", .pending, to: me))], rig: "r", me: me)
        #expect(tracker.update(ask, enabled: all).count == 1)
        #expect(tracker.update([], enabled: all).isEmpty)
        #expect(tracker.update(ask, enabled: all).count == 1)
    }

    @Test func disabledKindsArentPosted() {
        var tracker = NoticeTracker()
        _ = tracker.update([], enabled: all)
        let current = notices(
            entries: [.prompt(prompt("dev@r", "ls"), linked: nil), .qitem(item("q1", .pending, to: me))], rig: "r",
            me: me)
        #expect(tracker.update(current, enabled: [.ask]).map(\.kind) == [.ask])
    }

    @Test func asksAndRepliesAreToldApart() {
        var reply = item("q2", .pending, from: "orch@r", to: me)
        reply.humanIntent = "update"
        let ask = item("q1", .pending, from: "orch@r", to: me)
        let found = notices(entries: [.qitem(ask), .qitem(reply)], rig: "r", me: me)
        #expect(found.map(\.kind) == [.ask, .reply])
        #expect(found[0].title == "orch asks you")
        #expect(found[0].body == "summary q1")
        #expect(found[1].title == "orch replied")
        #expect(found[0].target == .qitem("q1"))
    }

    @Test func aSeatThatWentDownIsNoticed() {
        let seat = Seat(id: "s1", logicalId: "dev.one", sessionName: "dev@r", status: .detached)
        let found = notices(entries: [.seat(seat, .lost)], rig: "r", me: me)
        #expect(found.map(\.kind) == [.seatDown])
        #expect(found.first?.title == "dev went down")
    }

    @Test func anotherRigsCountPostsWhenItRises() {
        var tracker = NoticeTracker()
        _ = tracker.update(attentionNotices(["kernel": 1]), enabled: all)
        #expect(tracker.update(attentionNotices(["kernel": 1]), enabled: all).isEmpty)
        let risen = tracker.update(attentionNotices(["kernel": 2]), enabled: all)
        #expect(risen.map(\.title) == ["kernel: 2 seats need you"])
        #expect(risen.first?.target == .rig("kernel"))
        #expect(risen.first?.body.contains("npx") == false, "other rigs' prompts aren't read, so no command")
    }

    @Test func daemonDownWaitsOutAGracePeriod() {
        let since = Date(timeIntervalSince1970: 1000)
        #expect(daemonDownNotice(since: nil, now: since) == nil)
        #expect(daemonDownNotice(since: since, now: since.addingTimeInterval(20)) == nil, "a restart doesn't ping")
        let notice = daemonDownNotice(since: since, now: since.addingTimeInterval(31))
        #expect(notice?.kind == .daemonDown)
        #expect(notice?.key == daemonDownNotice(since: since, now: since.addingTimeInterval(90))?.key, "one per outage")
    }
}

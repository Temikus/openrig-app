import Foundation
import RigFixtures
import RigModel
import Testing

@testable import RigDomain

@Suite struct ForYouTests {
    /// Recorded on a test rig after its agent replied to the app twice: an update to human@host, a reply to the
    /// registered person (since approved), and the stuck-sweep row the agent then parked on human@host.
    @Test func recordedRepliesNeedYou() throws {
        let rows = try RigFixtures.decode("queue-for-you", as: [QItem].self)
        let update = try #require(rows.first { $0.destination == "human@host" })
        #expect(update.humanIntent == "update")
        #expect(update.evidenceRef == "/tmp/x/hello-reply.md")
        #expect(forYou(update, me: "sam@external") == .update, "human@host is you whoever is registered")
        #expect(
            needsYou(rows, me: "sam@external").map(\.id) == [
                "qitem-recovery-5e376758bad6b703", "qitem-20261118233320-298730cd764780d6",
            ])
    }

    @Test func decisionsBeforeUpdates() {
        let me = "sam@external"
        var fyi = item("fyi", .pending, to: me, updated: 1)
        fyi.humanIntent = "update"
        let ask = item("ask", .pending, to: me, updated: 2)
        let held = item("held", .blocked, updated: 3, blockedOn: "external:pr")
        let others = [item("theirs", .pending, to: "kim@external"), item("done", .done, to: me)]
        #expect(needsYou([fyi, ask, held] + others, me: me).map(\.id) == ["ask", "held", "fyi"])
        #expect(forYou(ask, me: me) == .decision, "a row with no intent is a decision, the daemon's default")
        #expect(forYou(others[0], me: me) == nil, "another person's row")
    }

    @Test func anUpdateWithQuestionsIsADecision() {
        var row = item("q", .pending, to: "human@host")
        row.humanIntent = "update"
        row.asksHuman = true
        #expect(forYou(row, me: "sam@external") == .decision)
    }

    @Test func aSweepFindingIsNotADecision() {
        var row = item("finding", .pending, from: "orch-lead@denkeeper", to: "sam@external")
        row.tags = ["stuck-sweep-finding", "recovery-for:qitem-1"]
        #expect(forYou(row, me: "sam@external") == .update)
    }

    @Test func waitingCountsAsksPromptsAndFYIs() {
        let me = "sam@external"
        var fyi = item("fyi", .pending, from: "lead@kernel", to: me)
        fyi.humanIntent = "update"
        let ask = item("ask", .pending, from: "lead@kernel", to: me)
        let other = waiting(
            rows: [fyi, ask, item("theirs", .pending, from: "lead@kernel", to: "kim@external")], me: me, attention: 2)
        #expect(other == Waiting(asks: 1, prompts: 2, fyis: 1))
        #expect(other.urgent == 3)
        #expect(other.summary == "1 ask · 2 prompts · 1 FYI")
        #expect(waiting([.qitem(ask), .qitem(fyi)], me: me) == Waiting(asks: 1, fyis: 1))
        #expect(Waiting().isEmpty && Waiting().summary.isEmpty)
    }

    /// The menu bar item draws only the count; VoiceOver hears what it means. FYIs alone stay quiet.
    @Test func menuBarLabelSaysHowManyNeedYou() {
        #expect(Waiting().menuBarLabel(appName: "OpenRig") == "OpenRig")
        #expect(Waiting(fyis: 3).menuBarLabel(appName: "OpenRig") == "OpenRig")
        #expect(Waiting(prompts: 1, fyis: 1).menuBarLabel(appName: "OpenRig") == "OpenRig, 1 needs you")
        #expect(Waiting(asks: 1, prompts: 1).menuBarLabel(appName: "OpenRig Canary") == "OpenRig Canary, 2 need you")
    }

    @Test func rowsFromOtherRigs() {
        let me = "sam@external"
        var fyi = item("fyi", .pending, from: "lead@kernel", to: me, updated: 1)
        fyi.humanIntent = "update"
        let ask = item("ask", .pending, from: "orch-lead@denkeeper", to: me, updated: 2)
        let here = item("here", .pending, from: "dev@apptest", to: me)
        let legacy = item("legacy", .pending, from: "dev@kernel", to: "human@host", updated: 3)
        let notMine = item("theirs", .pending, from: "dev@kernel", to: "kim@external")
        let closed = item("closed", .done, from: "dev@kernel", to: me)
        let rows = [fyi, ask, here, legacy, notMine, closed]
        #expect(forYouElsewhere(rows, me: me, excluding: "apptest").map(\.id) == ["ask", "legacy", "fyi"])
        #expect(forYouElsewhere(rows, me: me, excluding: nil).map(\.id) == ["here", "ask", "legacy", "fyi"])
        #expect(rigName(ofSession: "orch-lead@denkeeper") == "denkeeper")
        #expect(rigName(ofSession: "human@host") == "host")
        #expect(rigName(ofSession: "nobody") == nil)
    }

    @Test func outcomesInPlainWords() {
        func closed(_ reason: String?, _ resolution: String? = nil, state: QItemState = .done, target: String? = nil)
            -> Outcome?
        {
            var row = item("q", state, closureReason: reason, closureTarget: target)
            row.resolution = resolution
            return outcome(row)
        }
        #expect(closed("no-follow-on", "Approved · told orch-lead: go") == .approved)
        #expect(closed("no-follow-on", "approved") == .approved, "the TUI's approve")
        #expect(closed("denied", "Denied · told orch-lead") == .denied)
        #expect(closed("no-follow-on", "LGTM, two nits") == .done)
        var answered = item("a", .done, closureReason: "no-follow-on")
        answered.humanAnswers = ["builds": "both"]
        #expect(outcome(answered) == .answered)
        answered.humanAnswers = ["builds": .typedReply("Both, but b1 first.")]
        #expect(outcome(answered) == .answered, "a typed reply answers the ask too")
        #expect(closed(nil) == .done)
        #expect(closed(nil, state: .canceled) == .canceled)
        #expect(closed(nil, state: .denied) == .denied)
        #expect(closed("no-follow-on", state: .failed) == .failed)
        #expect(Outcome.failed.label == "Failed")
        #expect(closed("superseded", target: "qitem-2") == .replaced(by: "qitem-2"))
        #expect(closed("escalation", target: "lead@r") == .escalated(to: "lead@r"))
        #expect(closed("handed_off_to", target: "b@r") == .handedOff(to: "b@r"))
        #expect(outcome(item("open", .pending)) == nil)
        #expect(Outcome.done.label == "Done" && Outcome.replaced(by: nil).label == "Replaced")
    }
}

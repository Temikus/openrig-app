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
}

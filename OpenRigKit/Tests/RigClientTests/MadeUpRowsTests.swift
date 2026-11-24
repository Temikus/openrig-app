import Foundation
import RigModel
import Testing

@testable import RigClient

/// OPENRIG_DEBUG_ROW's rows: shown in a debug copy, never acted on.
@Suite struct MadeUpRowsTests {
    /// The shape `rig queue show --json` prints; its source is a real seat.
    static let file = Data(
        #"""
        [{"qitemId": "qitem-made-up-1", "sourceSession": "orch-lead@openrig-app", "destinationSession": "sam@external",
          "state": "pending", "summary": "Made up: approve this?", "evidenceRef": "task/x@abc1234"},
         {"qitemId": "qitem-real", "sourceSession": "orch-lead@openrig-app", "destinationSession": "sam@external",
          "state": "pending", "summary": "Same id as a real row"}]
        """#.utf8)

    let madeUp = MadeUpRows(json: Self.file)
    let real: [QItem] = try! JSONDecoder().decode(
        [QItem].self,
        from: Data(
            #"[{"qitemId": "qitem-real", "sourceSession": "a@x", "destinationSession": "b@x", "state": "pending"}]"#
                .utf8))

    @Test func readsOneRowOrAnArray() throws {
        #expect(madeUp.rows.map(\.id) == ["qitem-made-up-1", "qitem-real"])
        let one = try JSONSerialization.data(withJSONObject: [
            "qitemId": "qitem-one", "sourceSession": "a@x", "destinationSession": "b@x", "state": "pending",
        ])
        #expect(MadeUpRows(json: one).rows.map(\.id) == ["qitem-one"])
        #expect(MadeUpRows(json: nil).rows.isEmpty)
        #expect(MadeUpRows(json: Data("not json".utf8)).rows.isEmpty)
    }

    /// A made-up row never hides a real one, and only the rows it added count as made up.
    @Test func mergeAddsOnlyRowsTheQueueLacks() {
        let merged = madeUp.merge(into: real)
        #expect(merged.rows.map(\.id) == ["qitem-real", "qitem-made-up-1"])
        #expect(merged.rows[0].source == "a@x", "the real row stays")
        #expect(merged.added == ["qitem-made-up-1"])
    }

    /// Approve with Tell on would type "Approved: …" into the asker's terminal. On a made-up row nothing goes out.
    @Test func approvingAMadeUpRowSendsNothing() async throws {
        let item = try #require(madeUp.rows.first)
        let key = "answer:\(item.id)"
        var done: [RigAction] = []
        let result = await Answer(.approve, note: "looks fine", tell: true).run(on: item) { action in
            guard !madeUp.refuses(action, key: key) else { return false }
            done.append(action)
            return true
        }
        #expect(done.isEmpty)
        #expect(!result.closed)
    }

    /// The panel's Reply… composer sends under "answer:<id>|reply". Under the seat's own key ("send:<seat>") the
    /// same message would pass: the key is what ties a reply to its row.
    @Test func aReplyFromAMadeUpRowsPanelIsRefused() throws {
        let item = try #require(madeUp.rows.first)
        let reply = RigAction.send(session: item.source, text: "Can you say more?")
        #expect(madeUp.refuses(reply, key: "answer:\(item.id)|reply"))
        #expect(!madeUp.refuses(reply, key: "send:seat-orch-lead"))
    }

    @Test func refusesByKeyOrByTheRowTheActionNames() {
        let send = RigAction.send(session: "orch-lead@openrig-app", text: "hi")
        #expect(madeUp.refuses(send, key: "answer:qitem-made-up-1"))
        #expect(madeUp.refuses(send, key: "answer:qitem-made-up-1|reply"))
        #expect(!madeUp.refuses(send, key: "send:orch-lead@openrig-app"))
        let close = RigAction.close(id: "qitem-made-up-1", reason: .noFollowOn, target: nil, resolution: nil)
        #expect(madeUp.refuses(close, key: "row-actions"))
        #expect(madeUp.contains("qitem-made-up-1"))
        #expect(!MadeUpRows(json: nil).refuses(send, key: "answer:qitem-made-up-1"))
    }
}

import RigModel
import Testing

@testable import RigClient

struct AnswerTests {
    let item = QItem(
        id: "qitem-1", source: "orch-lead@denkeeper", destination: "sam@external", state: .pending,
        summary: "Start both builds?")

    /// Runs `answer`, recording each action; `failing` lists actions that fail, each once.
    private func run(
        _ answer: Answer, alreadySent: RigAction? = nil, failing: [RigAction] = []
    ) async -> (Answer.Result, [RigAction]) {
        var log: [RigAction] = []
        var failing = failing
        let result = await answer.run(on: item, alreadySent: alreadySent) { action in
            log.append(action)
            if let i = failing.firstIndex(of: action) {
                failing.remove(at: i)
                return false
            }
            return true
        }
        return (result, log)
    }

    @Test func approveTellsTheAskerThenClosesRecordingThatTheyWereTold() async {
        let (result, log) = await run(Answer(.approve, note: "  go ahead \n"))
        #expect(
            log == [
                .send(session: "orch-lead@denkeeper", text: "Approved: Start both builds? (qitem-1)\ngo ahead"),
                .close(
                    id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Approved · told orch-lead: go ahead"),
            ])
        #expect(result.told && result.closed)
        #expect(Answer(.approve).outcome(asker: "orch-lead", told: result.told) == "Approved · orch-lead told")
    }

    @Test func aBareDenyAsksTheAgentNotToRetryBlind() async {
        let (_, log) = await run(Answer(.deny))
        #expect(
            log == [
                .send(
                    session: "orch-lead@denkeeper",
                    text: "Denied: Start both builds? (qitem-1)\nNo reason given; ask before retrying."),
                .close(id: "qitem-1", reason: .denied, target: nil, resolution: "Denied · told orch-lead"),
            ])
    }

    @Test func aFailedMessageLeavesTheRowOpen() async {
        let answer = Answer(.approve)
        let (result, log) = await run(answer, failing: [answer.message(for: item)!])
        #expect(log.count == 1)
        #expect(result == .init(sent: nil, closed: false))
    }

    @Test func aRetryAfterAFailedCloseDoesNotTellTwice() async {
        let answer = Answer(.approve)
        let (first, firstLog) = await run(answer, failing: [answer.close(item, told: true)])
        #expect(firstLog.count == 2)
        #expect(first.told && !first.closed)

        let (second, secondLog) = await run(answer, alreadySent: first.sent)
        #expect(secondLog == [answer.close(item, told: true)])
        #expect(second.told && second.closed)
    }

    @Test func aChangedVerdictAfterAFailedCloseIsStillTold() async {
        let approve = Answer(.approve)
        let (first, _) = await run(approve, failing: [approve.close(item, told: true)])

        let deny = Answer(.deny, note: "not yet")
        let (_, log) = await run(deny, alreadySent: first.sent)
        let changed = "Changed: Denied: Start both builds? (qitem-1)\nnot yet"
        #expect(log == [.send(session: "orch-lead@denkeeper", text: changed), deny.close(item, told: true)])

        // Retrying the changed answer after another failed close doesn't send it again.
        let (third, retry) = await run(deny, alreadySent: deny.message(for: item))
        #expect(retry == [deny.close(item, told: true)])
        #expect(third.sent == deny.message(for: item))
    }

    @Test func untickingTellAfterASentMessageStillRecordsTheAskerAsTold() async {
        let approve = Answer(.approve)
        let (first, _) = await run(approve, failing: [approve.close(item, told: true)])
        let (_, log) = await run(Answer(.approve, tell: false), alreadySent: first.sent)
        #expect(
            log == [.close(id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Approved · told orch-lead")])
    }

    @Test func withoutTellOnlyClosesAndSaysSo() async {
        let (result, log) = await run(Answer(.approve, note: "fine", tell: false))
        #expect(log == [.close(id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Approved: fine")])
        #expect(Answer(.approve).outcome(asker: "orch-lead", told: result.told) == "Approved")
    }

    @Test func acknowledgementsAndQuestionsNeverSend() async {
        let (_, ack) = await run(Answer(.acknowledge))
        #expect(ack == [.close(id: "qitem-1", reason: .noFollowOn, target: nil, resolution: nil)])

        let (_, replied) = await run(Answer(.answered, replied: true))
        #expect(
            replied == [.close(id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Answered by message")])
        let (_, silent) = await run(Answer(.answered))
        #expect(
            silent == [
                .close(
                    id: "qitem-1", reason: .noFollowOn, target: nil, resolution: "Closed without a reply from the app")
            ])
        #expect(Answer(.acknowledge).outcome(asker: "orch-lead", told: false) == "Closed")
    }
}

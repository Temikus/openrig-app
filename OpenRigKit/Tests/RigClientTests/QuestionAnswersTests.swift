import Foundation
import RigModel
import Testing

@testable import RigClient

struct QuestionAnswersTests {
    /// As the daemon sends it: two questions, one option recommended, one answer already recorded on another row.
    let item: QItem = {
        let json = """
            {"qitemId": "qitem-1", "sourceSession": "orch-lead@denkeeper", "destinationSession": "sam@external",
             "state": "pending", "summary": "Two picks",
             "humanQuestions": [
               {"id": "builds", "question": "Which builds start now?",
                "options": [{"id": "both", "label": "Both", "recommended": true}, {"id": "b1", "label": "dev-b1 only"}]},
               {"id": "review", "question": "Who reviews?",
                "options": [{"id": "sec", "label": "review-security"}, {"id": "both", "label": "security, then design"}]}
             ],
             "humanAnswers": {}}
            """
        return try! JSONDecoder().decode(QItem.self, from: Data(json.utf8))
    }()

    @Test func decodesQuestionsAndAnswers() {
        #expect(item.asksHuman)
        #expect(item.humanQuestions.map(\.id) == ["builds", "review"])
        #expect(item.humanQuestions[0].options[0].recommended == true)
        #expect(item.humanQuestions[0].options[1].recommended == nil)
    }

    @Test func choicesInQuestionOrder() {
        let answers = QuestionAnswers(picks: ["review": "both", "builds": "both"])
        #expect(answers.missing(in: item).isEmpty)
        #expect(
            answers.calls(for: item) == [
                .choice(question: "builds", option: "both"), .choice(question: "review", option: "both"),
            ])
    }

    @Test func otherWordsGoLastInOneCall() {
        let one = QuestionAnswers(picks: ["builds": "b1"], other: ["review": "  ask design first "])
        #expect(one.calls(for: item) == [.choice(question: "builds", option: "b1"), .words("ask design first")])

        let two = QuestionAnswers(other: ["builds": "none yet", "review": "you decide"])
        #expect(two.calls(for: item) == [.words("Which builds start now? none yet\nWho reviews? you decide")])
    }

    @Test func emptyOtherWordsStillMissing() {
        let answers = QuestionAnswers(picks: ["builds": "both", "review": "sec"], other: ["review": " "])
        #expect(answers.missing(in: item).map(\.id) == ["review"], "Other was chosen but nothing written")
    }

    @Test func aRetrySkipsWhatTheRowAlreadyRecords() {
        var partly = item
        partly.humanAnswers = ["builds": "both"]
        let answers = QuestionAnswers(picks: ["builds": "both", "review": "sec"])
        #expect(answers.calls(for: partly) == [.choice(question: "review", option: "sec")])
    }

    @Test func rowsAnsweredInTurnKeepTheirOwnPicks() {
        var other = item
        other.id = "qitem-2"
        var drafts = AnswerDrafts()
        drafts.set(QuestionAnswers(picks: ["builds": "b1"]), for: "answer:qitem-1")
        drafts.set(QuestionAnswers(picks: ["builds": "both"], other: ["review": "ask"]), for: "answer:qitem-2")
        #expect(drafts.draft("answer:qitem-1", on: item) == QuestionAnswers(picks: ["builds": "b1"]))
        #expect(
            drafts.draft("answer:qitem-2", on: other)
                == QuestionAnswers(picks: ["builds": "both"], other: ["review": "ask"]))

        drafts.clear("answer:qitem-1")
        #expect(drafts.draft("answer:qitem-1", on: item) == QuestionAnswers())
        #expect(drafts.draft("answer:qitem-2", on: other).picks == ["builds": "both"])
    }

    @Test func anEmptyDraftIsNotKept() {
        var drafts = AnswerDrafts()
        drafts.set(QuestionAnswers(picks: ["builds": "b1"]), for: "answer:qitem-1")
        drafts.set(QuestionAnswers(), for: "answer:qitem-1")
        #expect(drafts == AnswerDrafts())
    }

    /// Another device answered "builds", and a new revision dropped option "sec" and added a question.
    @Test func aDraftShowsNoPickForAQuestionTheRowNoLongerAsks() {
        var drafts = AnswerDrafts()
        drafts.set(QuestionAnswers(picks: ["builds": "b1", "review": "sec", "gone": "x"]), for: "k")
        var changed = item
        changed.humanAnswers = ["builds": "both"]
        changed.humanQuestions[1].options.removeAll { $0.id == "sec" }
        #expect(drafts.draft("k", on: changed) == QuestionAnswers())

        drafts.set(QuestionAnswers(picks: ["review": "both"], other: ["builds": "later", "gone": "y"]), for: "k")
        #expect(drafts.draft("k", on: changed) == QuestionAnswers(picks: ["review": "both"]))
        #expect(drafts.draft("k", on: item) == QuestionAnswers(picks: ["review": "both"], other: ["builds": "later"]))
    }

    @Test func runStopsAtTheFirstFailure() async {
        var sent: [AskAnswer] = []
        let ok = await QuestionAnswers(picks: ["builds": "both", "review": "sec"]).run(on: item) { call in
            sent.append(call)
            return false
        }
        #expect(!ok && sent.count == 1)
    }
}

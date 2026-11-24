import Foundation
import Testing

@testable import RigModel

/// The daemon stores a button choice as the option id, and a typed reply as an object
/// (queue-repository.js `placeTypedReply`). Before this, one typed reply dropped every answer on the row.
@Suite struct HumanAnswerTests {
    func row(answers: String) throws -> QItem {
        let json = """
            {"qitemId": "qitem-1", "sourceSession": "orch-lead@denkeeper", "destinationSession": "sam@external",
             "state": "done", "summary": "Two picks",
             "humanQuestions": [
               {"id": "builds", "question": "Which builds start now?",
                "options": [{"id": "both", "label": "Both"}, {"id": "b1", "label": "dev-b1 only"}]},
               {"id": "review", "question": "Who reviews?",
                "options": [{"id": "sec", "label": "review-security"}]},
               {"id": "ship", "question": "Ship it?", "options": [{"id": "yes", "label": "Yes"}]}
             ],
             "humanAnswers": \(answers)}
            """
        return try JSONDecoder().decode(QItem.self, from: Data(json.utf8))
    }

    @Test func aButtonAnswerAndATypedReplyBothSurvive() throws {
        let item = try row(
            answers: """
                {"builds": "both",
                 "review": {"kind": "typed-reply", "text": "Ask design first.", "placement": "first-unanswered",
                            "unansweredCount": 0}}
                """)
        #expect(item.humanAnswers["builds"] == .option("both"))
        #expect(item.humanAnswers["review"] == .typedReply("Ask design first."))
        #expect(item.humanQuestions.filter { item.humanAnswers[$0.id] == nil }.map(\.id) == ["ship"])
    }

    /// The daemon counts any non-null value as answered, so an unknown shape counts too. Only null is no answer.
    @Test func anUnknownShapeIsKeptAndNullIsDropped() throws {
        let item = try row(answers: #"{"builds": {"kind": "voice-note"}, "review": 3, "ship": null}"#)
        #expect(item.humanAnswers == ["builds": .unrecognized, "review": .unrecognized])
    }

    @Test func anAnswerReadsAsTheOptionsLabelOrTheReplysWords() throws {
        let item = try row(answers: "{}")
        let builds = item.humanQuestions[0]
        #expect(HumanAnswer.option("b1").text(in: builds) == "dev-b1 only")
        #expect(HumanAnswer.option("gone").text(in: builds) == "gone")
        #expect(HumanAnswer.typedReply("Neither yet.").text(in: builds) == "Neither yet.")
        #expect(HumanAnswer.unrecognized.text(in: builds) == "An answer this app can't show")
    }
}

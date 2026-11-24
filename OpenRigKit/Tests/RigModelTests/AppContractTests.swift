import Foundation
import RigFixtures
import Testing

@testable import RigModel

@Suite struct AppContractDecoding {
    @Test func capabilitiesSupportAnswering() throws {
        let capabilities: AppCapabilities = try fixture("app-capabilities")
        #expect(capabilities.supportsAnswering)
        #expect(capabilities.actors == ["human-example@external"])
    }

    @Test func anotherContractOrVersionDoesNotSupportAnswering() throws {
        let json = #"{"contract":"openrig.core-app","version":2,"jobs":[{"id":"human-answer"}]}"#
        let capabilities = try JSONDecoder().decode(AppCapabilities.self, from: Data(json.utf8))
        #expect(!capabilities.supportsAnswering)
    }

    @Test func needsMeListsAnswerableRequests() throws {
        let needs: AppNeedsMe = try fixture("app-needs-me")
        #expect(needs.isComplete)
        #expect(needs.requests.map(\.id) == ["qitem-20261123101500-6a1f", "qitem-20261123102200-9c2e"])

        let first = needs.requests[0]
        #expect(first.isAnswerable)
        #expect(first.decisionRevision == "dr1-0a1b2c3d4e5f60718293a4b5")
        #expect(first.episodeKey == nil)
        #expect(first.questions.count == 2)
        #expect(first.unansweredQuestions.map(\.id) == ["notify"])
        #expect(!first.occupantAuthorityUnknown)

        let permission = needs.requests[1]
        #expect(permission.episodeKey == "episode-2")
        #expect(permission.occupantAuthorityUnknown)
    }

    /// Disappearance never means resolution: an unavailable source is not an empty list.
    @Test func unavailableSourceIsNotComplete() throws {
        let needs: AppNeedsMe = try fixture("app-needs-me-unavailable")
        #expect(needs.requests.isEmpty)
        #expect(!needs.isComplete)
    }

    @Test func unsupportedRequestSaysWhy() throws {
        let request: AppRequest = try fixture("app-request-unsupported")
        #expect(!request.isAnswerable)
        #expect(request.unsupportedReason == "unsupported_request_kind")
        #expect(request.questions.isEmpty)
    }

    /// One bad entry drops only itself. A source that can't be read still keeps the list from counting as complete.
    @Test func aBadEntryHidesOnlyItself() throws {
        // The recorded list, with the first ask's id and a second source's fields broken.
        var json = try JSONSerialization.jsonObject(with: RigFixtures.data("app-needs-me")) as! [String: Any]
        var requests = json["requests"] as! [[String: Any]]
        requests[0]["requestId"] = nil
        json["requests"] = requests
        json["sources"] = (json["sources"] as! [[String: Any]]) + [["source": 7]]
        let needs = try JSONDecoder().decode(AppNeedsMe.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(needs.requests.map(\.id) == ["qitem-20261123102200-9c2e"])
        #expect(needs.sources.count == 2)
        #expect(!needs.isComplete)
    }

    @Test func emptyNeedsMeFromAnAvailableSourceIsComplete() throws {
        let needs: AppNeedsMe = try fixture("app-needs-me-empty")
        #expect(needs.requests.isEmpty)
        #expect(needs.isComplete)
    }

    /// An ask the person already answered: options and a typed reply side by side, nothing left to answer.
    @Test func answeredRequestKeepsEveryAnswer() throws {
        let request: AppRequest = try fixture("app-request-answered")
        #expect(!request.isAnswerable)
        #expect(request.unsupportedReason == "request_not_pending")
        #expect(request.questions.count == 4)
        #expect(request.humanAnswers.count == 4)
        #expect(request.humanAnswers["q1"] == .typedReply("Reply text."))
        #expect(request.humanAnswers["q4"] == .option("a"))
        #expect(request.unansweredQuestions.isEmpty)
    }

    @Test func resultReadsTheActualReturn() throws {
        let result: AppResult = try fixture("app-result")
        #expect(result.answerReturn?.status == "returned")
        #expect(result.answerReturn?.replyQitemId == "qitem-human-answer-c573b0e2236c08eb2d77")
        #expect(result.request?.id == "qitem-20261123113142-c22e377fcc7b1303")
        #expect(result.request?.humanAnswers.count == 4)
        #expect(result.permissionStatus == "not-applicable")
        #expect(result.isComplete)
    }

    @Test func credentialHidesItsToken() throws {
        let credential: AppCredential = try fixture("app-credential")
        #expect(credential.id == "70cfe276-ec37-44e5-ae7c-6515ef5ff2ee")
        #expect(credential.actors == ["human-example@external"])
        #expect(credential.token.hasPrefix("orapp_"))
        #expect(!String(describing: credential).contains(credential.token))
        #expect(!String(reflecting: credential).contains(credential.token))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains(credential.token))
    }

    /// A typed reply is stored as an object, a button choice as a string. Both count as answered.
    @Test func typedReplyAndChoiceBothSurvive() throws {
        let request: AppRequest = try fixture("app-request-typed-reply")
        #expect(request.humanAnswers["reach"] == .option("tailscale"))
        #expect(request.humanAnswers["notify"] == .typedReply("Reply text."))
        #expect(request.unansweredQuestions.map(\.id) == ["simulator"])
    }

    /// The daemon counts any non-null value as answered, so an unknown shape must too: else a typed reply would be
    /// filed under a question the daemon thinks is answered.
    @Test func unknownAnswerShapeStillCountsAsAnswered() throws {
        var json = try String(decoding: RigFixtures.data("app-request-typed-reply"), as: UTF8.self)
        json = json.replacingOccurrences(of: #""reach": "tailscale""#, with: #""reach": {"kind": "voice-note"}"#)
        let request = try JSONDecoder().decode(AppRequest.self, from: Data(json.utf8))
        #expect(request.humanAnswers["reach"] == .unrecognized)
        #expect(request.humanAnswers["notify"] == .typedReply("Reply text."))
        #expect(request.unansweredQuestions.map(\.id) == ["simulator"])
    }
}

@Suite struct AppReceiptFate {
    @Test func returnedToTheAsker() throws {
        let receipt: AppAnswerReceipt = try fixture("app-receipt-returned")
        #expect(receipt.fate == .returned(reply: "qitem-20261123103104-e41b"))
        #expect(!receipt.replayed)
    }

    @Test func partialChoiceWaitsForTheRest() throws {
        let receipt: AppAnswerReceipt = try fixture("app-receipt-recorded")
        // The daemon sends the open questions' text, not their ids.
        #expect(receipt.fate == .partial(unansweredText: ["Question two?"]))
        #expect(receipt.replayed)
    }

    @Test func permissionAnswerStaysOnTheRequest() throws {
        let receipt: AppAnswerReceipt = try fixture("app-receipt-kept")
        #expect(receipt.fate == .answeredInPlace(message: "Message text."))
    }

    @Test func alreadyAnsweredNamesTheOriginalReturn() throws {
        let receipt: AppAnswerReceipt = try fixture("app-receipt-already-answered")
        #expect(receipt.fate == .alreadyAnswered(reply: "qitem-20261123103104-e41b"))
    }

    @Test func conflictNeedsANewDecision() throws {
        let receipt: AppAnswerReceipt = try fixture("app-answer-conflict")
        #expect(receipt.fate == .conflict("decision_revision_changed"))
        #expect(receipt.retrySameSubmission == false)
    }
}

@Suite struct AppAnswerBindingTests {
    func request() throws -> AppRequest {
        try fixture("app-needs-me", as: AppNeedsMe.self).requests[0]
    }

    @Test func choiceBindsTheReadRevisionAndEpisode() throws {
        let binding = try #require(AppAnswerBinding.choosing("later", for: "notify", in: request(), as: "a@external"))
        #expect(binding.requestId == "qitem-20261123101500-6a1f")
        #expect(binding.expectedRevision == "dr1-0a1b2c3d4e5f60718293a4b5")
        #expect(binding.answer == .option("later"))
    }

    @Test func choiceOfAnUnknownOptionIsNil() throws {
        #expect(AppAnswerBinding.choosing("nope", for: "notify", in: try request(), as: "a@external") == nil)
        #expect(AppAnswerBinding.choosing("later", for: "nope", in: try request(), as: "a@external") == nil)
    }

    /// A typed reply answers the whole ask, filed under the first question still open.
    @Test func typedReplyGoesToTheFirstUnansweredQuestion() throws {
        let binding = try #require(AppAnswerBinding.replying("  Ship it  ", to: request(), as: "a@external"))
        #expect(binding.questionId == "notify")
        #expect(binding.answer == .typedReply("Ship it"))
    }

    @Test(arguments: ["", "   ", "a\u{0}b", String(repeating: "x", count: 16 * 1024 + 1)])
    func typedReplyRefusesWhatTheDaemonRefuses(text: String) throws {
        #expect(AppAnswerBinding.replying(text, to: try request(), as: "a@external") == nil)
    }

    @Test func unanswerableRequestHasNoBinding() throws {
        let unsupported: AppRequest = try fixture("app-request-unsupported")
        #expect(AppAnswerBinding.replying("yes", to: unsupported, as: "a@external") == nil)
    }

    /// The daemon wants exactly these keys, with a null episode written out, not left off.
    @Test func encodesTheExactWireShape() throws {
        let binding = try #require(AppAnswerBinding.choosing("later", for: "notify", in: request(), as: "a@external"))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        #expect(
            Set(object.keys) == ["job", "actor", "requestId", "questionId", "episodeKey", "expectedRevision", "answer"])
        #expect(object["job"] as? String == "human-answer")
        #expect(object["episodeKey"] is NSNull)
        #expect(object["answer"] as? [String: String] == ["kind": "option", "optionId": "later"])

        let reply = try #require(AppAnswerBinding.replying("Ship it", to: request(), as: "a@external"))
        let replyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        #expect(replyObject["answer"] as? [String: String] == ["kind": "typed-reply", "text": "Ship it"])
    }

    /// The app saves the binding before sending, so it must come back identical.
    @Test func survivesSavingToDisk() throws {
        let binding = try #require(AppAnswerBinding.replying("Ship it", to: request(), as: "a@external"))
        let saved = try JSONDecoder().decode(AppAnswerBinding.self, from: JSONEncoder().encode(binding))
        #expect(saved == binding)
    }

    @Test func answerIDsMatchTheDaemonsRule() {
        let ids = (0..<20).map { _ in AppAnswerID.random() }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.wholeMatch(of: /[A-Za-z0-9_-]{8,128}/) != nil })
    }
}

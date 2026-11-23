import Foundation
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

    @Test func resultReadsTheActualReturn() throws {
        let result: AppResult = try fixture("app-result")
        #expect(result.answerReturn?.status == "returned")
        #expect(result.answerReturn?.replyQitemId == "qitem-20261123103104-e41b")
        #expect(result.request?.id == "qitem-20261123101500-6a1f")
        #expect(result.isComplete)
    }

    @Test func credentialHidesItsToken() throws {
        let credential: AppCredential = try fixture("app-credential")
        #expect(credential.id == "5f0c2a9e-7b1d-4e63-9a8f-2c4b6d8e0f13")
        #expect(credential.actors == ["human-example@external"])
        #expect(credential.token.hasPrefix("orapp_"))
        #expect(!String(describing: credential).contains(credential.token))
        #expect(!String(reflecting: credential).contains(credential.token))
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
        #expect(receipt.fate == .partial(unanswered: ["notify"]))
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

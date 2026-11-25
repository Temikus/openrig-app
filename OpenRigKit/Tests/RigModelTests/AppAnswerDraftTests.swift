import Foundation
import RigFixtures
import Testing

@testable import RigModel

@Suite struct AppAnswerDraftTests {
    /// The fixture's first ask, with nothing answered yet: "reach" (tailscale, wifi) and "notify" (later, push).
    func freshAsk() throws -> AppRequest {
        var request = try fixture("app-needs-me", as: AppNeedsMe.self).requests[0]
        request.humanAnswers = [:]
        return request
    }

    @Test func nothingIsSentUntilEveryOpenQuestionIsPicked() throws {
        let request = try freshAsk()
        var draft = AppAnswerDraft(picks: ["reach": "wifi"])
        #expect(draft.pickedCount(in: request) == 1)
        #expect(draft.submissions(for: request) == nil)
        draft.picks["notify"] = "push"
        #expect(draft.pickedCount(in: request) == 2)
        #expect(
            draft.submissions(for: request) == [
                AppAnswerDraft.Submission(questionID: "reach", form: .option("wifi")),
                AppAnswerDraft.Submission(questionID: "notify", form: .option("push")),
            ])
    }

    /// The questions go in the ask's order, whatever order they were picked in.
    @Test func submissionsFollowTheAsksOrder() throws {
        let request = try freshAsk()
        let draft = AppAnswerDraft(picks: ["notify": "later", "reach": "tailscale"])
        #expect(draft.submissions(for: request)?.map(\.questionID) == ["reach", "notify"])
    }

    /// A question answered elsewhere isn't sent again, and doesn't count.
    @Test func anAnsweredQuestionIsLeftOut() throws {
        var request = try freshAsk()
        request.humanAnswers = ["reach": .option("tailscale")]
        let draft = AppAnswerDraft(picks: ["reach": "wifi", "notify": "push"])
        #expect(draft.pickedCount(in: request) == 1)
        #expect(
            draft.submissions(for: request) == [AppAnswerDraft.Submission(questionID: "notify", form: .option("push"))])
    }

    /// A typed reply answers the whole ask: one submission, filed under the first open question, picks ignored.
    @Test func aReplyReplacesThePicks() throws {
        let request = try freshAsk()
        let draft = AppAnswerDraft(picks: ["reach": "wifi"], reply: "  Wi-Fi, but ask me again in May.  ")
        #expect(
            draft.submissions(for: request) == [
                AppAnswerDraft.Submission(questionID: "reach", form: .typedReply("Wi-Fi, but ask me again in May."))
            ])
    }

    @Test(arguments: ["", "   \n", "nul\0inside", String(repeating: "x", count: 16 * 1024 + 1)])
    func aReplyTheDaemonWouldRefuseIsNotSent(text: String) throws {
        #expect(AppAnswerDraft(reply: text).submissions(for: try freshAsk()) == nil)
    }

    @Test func anAskTheContractCantAnswerSendsNothing() throws {
        var request = try freshAsk()
        request.isAnswerable = false
        #expect(AppAnswerDraft(picks: ["reach": "wifi", "notify": "push"]).submissions(for: request) == nil)
        #expect(AppAnswerDraft(reply: "Fine.").submissions(for: request) == nil)
    }

    /// Another device answered "reach", and a new revision dropped option "push".
    @Test func aKeptDraftShowsOnlyWhatTheAskStillOffers() throws {
        var request = try freshAsk()
        let draft = AppAnswerDraft(picks: ["reach": "wifi", "notify": "push", "gone": "x"], reply: "words")
        request.humanAnswers = ["reach": .option("tailscale")]
        request.questions[1].options.removeAll { $0.id == "push" }
        #expect(draft.kept(for: request) == AppAnswerDraft(picks: [:], reply: "words"))
    }

    @Test func draftsAreKeptPerAskAndEmptyOnesDropped() throws {
        let request = try freshAsk()
        var drafts = AppAnswerDrafts()
        drafts.set(AppAnswerDraft(picks: ["reach": "wifi"]), for: request.id)
        drafts.set(AppAnswerDraft(picks: ["reach": "tailscale"]), for: "qitem-other")
        #expect(drafts.draft(for: request) == AppAnswerDraft(picks: ["reach": "wifi"]))
        drafts.set(AppAnswerDraft(), for: request.id)
        #expect(drafts.draft(for: request) == AppAnswerDraft())
        drafts.clear("qitem-other")
        #expect(drafts == AppAnswerDrafts())
    }

    /// The binding the contract wants, built at a given revision: the first from the read, later ones from receipts.
    @Test func aSubmissionBindsAtTheRevisionItIsGiven() throws {
        let request = try freshAsk()
        let submission = AppAnswerDraft.Submission(questionID: "notify", form: .option("push"))
        let binding = submission.binding(on: request, at: "dr1-after", as: "human-example@external")
        #expect(binding.requestId == request.id)
        #expect(binding.questionId == "notify")
        #expect(binding.expectedRevision == "dr1-after")
        #expect(binding.episodeKey == request.episodeKey)
        #expect(binding.answer == .option("push"))
    }

    @Test func aReceiptGivesTheRevisionAfterIt() throws {
        let receipt: AppAnswerReceipt = try fixture("app-receipt-recorded")
        #expect(receipt.submission.revisionAfter == "dr1-0a1b2c3d4e5f60718293a4b5")
    }
}

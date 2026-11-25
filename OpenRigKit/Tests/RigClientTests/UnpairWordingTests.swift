import Testing

@testable import RigClient

/// At large text sizes the alert cuts its message, so a warning that answers will be dropped goes in the title.
@Suite struct UnpairWordingTests {
    let tail =
        "You'll need a new code from the Mac. Studio Mac still lists this phone until you unpair it there, under Settings › Phone."

    @Test func pairAgainWithNothingWaiting() {
        let words = UnpairWording(.pairAgain, mac: "Studio Mac", unsent: 0)
        #expect(words.title == "Forget Studio Mac and pair again?")
        #expect(words.message == tail)
        #expect(words.confirm == "Forget and Pair Again")
    }

    @Test func pairAgainWithAnswersWaiting() {
        let words = UnpairWording(.pairAgain, mac: "Studio Mac", unsent: 2)
        #expect(words.title == "Drop 2 unsent answers and pair again?")
        #expect(words.message == "They haven't reached Studio Mac. " + tail)
        let one = UnpairWording(.pairAgain, mac: "Studio Mac", unsent: 1)
        #expect(one.title == "Drop 1 unsent answer and pair again?")
        #expect(one.message == "It hasn't reached Studio Mac. " + tail)
    }

    @Test func unpairWithAndWithoutAnswersWaiting() {
        #expect(UnpairWording(.unpair, mac: "Studio Mac", unsent: 0).title == "Unpair this phone?")
        let waiting = UnpairWording(.unpair, mac: "Studio Mac", unsent: 3)
        #expect(waiting.title == "Drop 3 unsent answers and unpair?")
        #expect(waiting.message == "They haven't reached Studio Mac. " + tail)
        #expect(waiting.confirm == "Unpair")
    }
}

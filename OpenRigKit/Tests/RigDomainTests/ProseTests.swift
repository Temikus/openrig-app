import Testing

@testable import RigDomain

@Suite struct ProseTests {
    @Test func joinsHardWrappedLinesInAParagraph() {
        let body =
            "Pick ready denkeeper issues the team could be\nworking on, then have them built\nand\nreviewed by this team."
        #expect(
            reflowedProse(body)
                == "Pick ready denkeeper issues the team could be working on, then have them built and reviewed by this team."
        )
    }

    @Test func keepsParagraphBreaksListsAndHeadings() {
        let body =
            "# Plan\nFirst line\nsecond line\n\n- one\n- two that wraps\n  onto the next line\n1. numbered\n> quoted"
        #expect(
            reflowedProse(body)
                == "# Plan\nFirst line second line\n\n- one\n- two that wraps onto the next line\n1. numbered\n> quoted"
        )
    }

    @Test func leavesFencedCodeAlone() {
        let body = "Run:\n```\nrig queue list\n  --json\n```\nthen\nread it."
        #expect(reflowedProse(body) == "Run:\n```\nrig queue list\n  --json\n```\nthen read it.")
    }
}

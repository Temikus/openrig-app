import Testing

@testable import RigDomain

@Suite struct PreflightNotesTests {
    static let seats = ["orch.lead", "review.r1", "review.r2"]

    /// `rig spec preflight` on the Code review template with models set (2026-11-25): nine lines for three seats.
    static let warnings = [
        "orch.lead: configured model 'opus' is unverified. Launch checks do not establish model availability or account entitlement; no model call is made to verify it.",
        "orch.lead: permission_policy absent; launch_posture=floor",
        "orch.lead: no permission policy, so this seat launches at the floor with the team default's allowances, unless it has its own permission mode, Codex envelope or named Codex profile",
        "review.r1: configured model 'opus' is unverified. Launch checks do not establish model availability or account entitlement; no model call is made to verify it.",
        "review.r1: permission_policy absent; launch_posture=floor",
        "review.r1: no permission policy, so this seat launches at the floor with the team default's allowances, unless it has its own permission mode, Codex envelope or named Codex profile",
        "review.r2: configured model 'gpt-6-astra' is unverified. Launch checks do not establish model availability or account entitlement; no model call is made to verify it.",
        "review.r2: permission_policy absent; launch_posture=floor",
        "review.r2: no permission policy, so this seat launches at the floor with the team default's allowances, unless it has its own permission mode, Codex envelope or named Codex profile",
    ]

    @Test func eachThingIsOneRowNamingItsSeats() {
        let notes = PreflightNote.group(Self.warnings, seats: Self.seats)
        #expect(notes.map(\.text) == [PreflightNote.modelUnchecked, PreflightNote.noPolicy])
        #expect(notes[0].seats == ["lead (opus)", "r1 (opus)", "r2 (gpt-6-astra)"])
        #expect(notes[1].seats == ["lead", "r1", "r2"])
        // OpenRig's two wordings stay available, once each.
        #expect(notes[1].detail.count == 2)
    }

    @Test func otherMessagesKeepOpenRigsWordsAndGroupWhenIdentical() {
        let notes = PreflightNote.group(
            [
                "review.r1: Resolved cwd '/x' is inside the OpenRig installation",
                "review.r2: Resolved cwd '/x' is inside the OpenRig installation", "Spec has no pods",
            ],
            seats: Self.seats)
        #expect(notes.map(\.text) == ["Resolved cwd '/x' is inside the OpenRig installation", "Spec has no pods"])
        #expect(notes[0].seats == ["r1", "r2"])
        #expect(notes[1].seats.isEmpty)
    }
}

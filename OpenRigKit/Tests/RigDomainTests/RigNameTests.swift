import Testing

@testable import RigDomain

@Suite struct RigNameTests {
    @Test func aFolderNameBecomesARigName() {
        #expect(RigName.suggested("Payments Service") == "payments-service")
        #expect(RigName.suggested("openrig_app") == "openrig_app")
    }

    @Test func namesMustBeAddressable() {
        #expect(RigName.problem("") == "Name the rig.")
        #expect(RigName.problem("pay ments") != nil)
        #expect(RigName.problem("-pay") != nil)
        #expect(RigName.problem("pay-2_x") == nil)
    }

    @Test func anUntypedNameFollowsTheFolder() {
        #expect(RigName.afterPicking(folder: "Billing", current: "payments", typed: false, saved: false) == "billing")
        #expect(RigName.afterPicking(folder: "Billing", current: "mine", typed: true, saved: false) == "mine")
    }

    /// QA on 2a61930: a folder picked after the save renamed the rig, and the saved spec with it.
    @Test func afterTheSaveANewFolderKeepsTheName() {
        #expect(RigName.afterPicking(folder: "Billing", current: "payments", typed: false, saved: true) == "payments")
    }
}

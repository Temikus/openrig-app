import Foundation
import RigFixtures
import Testing

@testable import RigModel

@Suite struct HumanTests {
    @Test func humanAddressesMatchTheDaemon() {
        for address in ["human@host", "human@kernel", "human-artem@host", "human-a.b_c@kernel"] {
            #expect(Human.isAddress(address), "\(address)")
        }
        // operator-human@kernel is the TUI's pane, an ordinary seat: replies to it are typed into the TUI.
        for address in ["operator-human@kernel", "human@denkeeper", "humans@host", "human-@host", "sarah@external"] {
            #expect(!Human.isAddress(address), "\(address)")
        }
        #expect(Human.isAddress(Human.session))
        #expect(Human.isYou("human@kernel") && !Human.isYou("human-sarah@host"))
    }
}

@Suite struct GatewayIdentityTests {
    /// Recorded from 0.7.11 after `rig gateway human add … --default` (name scrubbed).
    @Test func actsAsTheDefaultPerson() throws {
        let gateway = try RigFixtures.decode("gateway-participants", as: GatewayParticipants.self)
        #expect(gateway.defaultID == "sam")
        #expect(Human.address(in: gateway) == "sam@external")
    }

    @Test func fallsBackToTheUnnamedPerson() throws {
        let empty = try JSONDecoder().decode(
            GatewayParticipants.self, from: Data(#"{"ok":true,"participants":[],"default":null}"#.utf8))
        #expect(Human.address(in: empty) == "human@host")
        #expect(Human.address(in: nil) == "human@host")
        // A default whose row is missing still gets the gateway's address form.
        #expect(Human.address(in: GatewayParticipants(defaultID: "kim")) == "kim@external")
    }
}

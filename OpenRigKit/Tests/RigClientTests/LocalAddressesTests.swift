import RigModel
import Testing

@testable import RigClient

@Suite struct LocalAddressesTests {
    /// Whatever this machine has, only home-network addresses come back, and never loopback.
    @Test func onlyPrivateIPv4() {
        for address in LocalAddresses.lan() {
            #expect(PairingCode.Reach.Kind.lan.accepts(address), "\(address)")
            #expect(address != "127.0.0.1")
        }
    }
}

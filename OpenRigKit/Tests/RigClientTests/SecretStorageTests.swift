import Foundation
import Testing

@testable import RigClient

/// An agent's test copy is re-signed ad hoc on every build, so a Keychain read there asks the person on their screen.
@Suite struct SecretStorageTests {
    @Test func onlyADebugAgentCopyKeepsSecretsInMemory() {
        #expect(SecretStorage.choose(bundleID: "dev.openrig.OpenRig.agent", debug: true) == .memory)
        #expect(SecretStorage.choose(bundleID: "dev.openrig.OpenRig.agent", debug: false) == .keychain)
        #expect(SecretStorage.choose(bundleID: "dev.openrig.OpenRig", debug: true) == .keychain)
        #expect(SecretStorage.choose(bundleID: "dev.openrig.OpenRig.canary", debug: true) == .keychain)
        #expect(SecretStorage.choose(bundleID: nil, debug: true) == .keychain)
    }

    @Test func memorySecretsSaveReadAndForget() {
        let secrets = MemorySecrets()
        #expect(secrets.read("a") == nil)
        secrets.save(Data("one".utf8), for: "a")
        secrets.save(Data("two".utf8), for: "a")
        #expect(secrets.read("a") == Data("two".utf8))
        secrets.forget("a")
        #expect(secrets.read("a") == nil)
    }
}

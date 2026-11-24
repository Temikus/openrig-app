import Foundation
import RigModel
import Synchronization
import Testing

@testable import RigClient

@MainActor @Suite struct RemoteSessionTests {
    static func link(_ host: String, name: String = "Mac") -> String {
        "openrig-remote://pair?v=1&reach=loopback:7433:\(host)&actor=human-example@external&credential=c&token=orapp_t1&name=\(name)"
    }
    let linkA = Self.link("127.0.0.1", name: "A")
    let linkB = Self.link("localhost", name: "B")

    /// A connect that answers per host from a table, and can hold one host until released.
    final class FakeMac: Sendable {
        let replies: [String: RemoteStatus]
        let held: String?
        private let calls = Mutex<[String]>([])
        private let gate = AsyncStream<Void>.makeStream()
        private let arrived = AsyncStream<Void>.makeStream()

        init(_ replies: [String: RemoteStatus], holding held: String? = nil) {
            self.replies = replies
            self.held = held
        }

        var hosts: [String] { calls.withLock { $0 } }
        func release() { gate.continuation.yield() }
        func waitUntilHeld() async { for await _ in arrived.stream { return } }

        func connect(_ code: PairingCode) async -> RemoteConnector.Outcome {
            let host = code.reaches[0].addresses[0]
            calls.withLock { $0.append(host) }
            if host == held {
                arrived.continuation.yield()
                for await _ in gate.stream { break }
            }
            return RemoteConnector.Outcome(status: replies[host] ?? .unreachable(detail: host), client: nil)
        }
    }

    func session(_ mac: FakeMac, store: any PairingStore = MemoryPairingStore()) -> RemoteSession {
        RemoteSession(store: store, connect: { await mac.connect($0) })
    }

    @Test func aScannedLinkPairsChecksAndIsStored() async throws {
        let store = MemoryPairingStore()
        let mac = FakeMac(["127.0.0.1": .unsupportedDaemon])
        let remote = session(mac, store: store)
        remote.pair(link: linkA)
        #expect(try store.load()?.code.name == "A")
        await remote.refresh()
        #expect(remote.status == .unsupportedDaemon)
        #expect(remote.macName == "A")
        #expect(remote.answeringAs == "human-example")
    }

    @Test func anOpenedLinkWaitsForTheYes() throws {
        let store = MemoryPairingStore()
        let remote = session(FakeMac([:]), store: store)
        remote.receive(openedLink: linkA)
        #expect(remote.pendingCode?.name == "A")
        #expect(try store.load() == nil)
        remote.confirmPending()
        #expect(remote.pendingCode == nil)
        #expect(try store.load()?.code.name == "A")
    }

    @Test func aBrokenLinkSaysWhyAndStoresNothing() throws {
        let store = MemoryPairingStore()
        let remote = session(FakeMac([:]), store: store)
        remote.pair(link: "openrig-remote://pair?v=9")
        #expect(remote.pairingError?.contains("newer OpenRig") == true)
        #expect(try store.load() == nil)
    }

    /// A check still running for the old pairing must not leave the new one on "Connecting…".
    @Test func aCheckForAnOldPairingRunsAgainForTheNewOne() async throws {
        let mac = FakeMac(["localhost": .unsupportedDaemon], holding: "127.0.0.1")
        let remote = session(
            mac, store: MemoryPairingStore(RemotePairing(code: try PairingCode(parsing: linkA), pairedAt: .now)))
        let running = Task { await remote.refresh() }
        await mac.waitUntilHeld()
        remote.pair(link: linkB)
        mac.release()
        await running.value
        #expect(remote.pairing?.code.name == "B")
        #expect(remote.status == .unsupportedDaemon)
        #expect(mac.hosts.prefix(2) == ["127.0.0.1", "localhost"])
    }

    @Test func unpairingDuringACheckLeavesNoStatus() async throws {
        let mac = FakeMac([:], holding: "127.0.0.1")
        let remote = session(
            mac, store: MemoryPairingStore(RemotePairing(code: try PairingCode(parsing: linkA), pairedAt: .now)))
        let running = Task { await remote.refresh() }
        await mac.waitUntilHeld()
        remote.unpair()
        mac.release()
        await running.value
        #expect(remote.pairing == nil)
        #expect(remote.status == nil)
    }

    @Test func aFailedSaveKeepsTheOldPairing() throws {
        let old = RemotePairing(code: try PairingCode(parsing: linkA), pairedAt: .now)
        let store = FailingStore(old, failing: .save)
        let remote = session(FakeMac([:]), store: store)
        remote.pair(link: linkB)
        #expect(remote.pairing == old)
        #expect(remote.pairingError?.contains("Keychain") == true)
    }

    /// The token would still be on the phone: say so rather than look unpaired.
    @Test func aFailedUnpairSaysSoAndStaysPaired() throws {
        let old = RemotePairing(code: try PairingCode(parsing: linkA), pairedAt: .now)
        let remote = session(FakeMac([:]), store: FailingStore(old, failing: .delete))
        remote.unpair()
        #expect(remote.pairing == old)
        #expect(remote.pairingError?.contains("Keychain") == true)
    }

    @Test func aStatusOverrideReplacesTheCheckedStatus() async throws {
        let remote = session(FakeMac(["127.0.0.1": .unsupportedDaemon]))
        remote.statusOverride = .localNetworkDenied
        remote.pair(link: linkA)
        await remote.refresh()
        #expect(remote.status == .localNetworkDenied)
    }
}

/// A store whose save or delete fails, as a locked or full Keychain might.
final class FailingStore: PairingStore {
    enum Step { case save, delete }
    struct Failure: Error {}
    let inner: MemoryPairingStore
    let failing: Step

    init(_ pairing: RemotePairing?, failing: Step) {
        inner = MemoryPairingStore(pairing)
        self.failing = failing
    }

    func load() throws -> RemotePairing? { try inner.load() }
    func save(_ pairing: RemotePairing) throws {
        if failing == .save { throw Failure() }
        try inner.save(pairing)
    }
    func delete() throws {
        if failing == .delete { throw Failure() }
        try inner.delete()
    }
}

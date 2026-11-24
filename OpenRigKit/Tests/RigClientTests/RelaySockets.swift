import Foundation
import Testing

@testable import RigClient

/// `.relaySockets` on a suite that opens relay sockets on 127.0.0.1: its tests take one lock shared by every such
/// suite, so only one runs at a time. Side by side they churned loopback connections, and a connect now and then
/// failed with EADDRINUSE (POSIX 48).
struct RelaySockets: SuiteTrait, TestTrait, TestScoping {
    static let gate = AsyncSerial()

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // The suite's own scope passes through: holding the lock there would block its tests.
        guard testCase != nil else { return try await function() }
        try await Self.gate.run { try await function() }
    }
}

extension Trait where Self == RelaySockets {
    static var relaySockets: Self { Self() }
}

/// Two suites with the trait, each with tests that stay inside for a moment: no two may be inside at once. Without
/// the lock, Swift Testing runs the suites side by side.
enum RelaySocketsProbe {
    static let lock = NSLock()
    nonisolated(unsafe) static var inside = 0
    nonisolated(unsafe) static var most = 0

    static func stay() async throws {
        lock.withLock {
            inside += 1
            most = max(most, inside)
        }
        try await Task.sleep(for: .milliseconds(60))
        lock.withLock { inside -= 1 }
        #expect(lock.withLock { most } == 1, "two relay-socket tests ran at once")
    }
}

@Suite(.relaySockets) struct RelaySocketsProbeA {
    @Test func one() async throws { try await RelaySocketsProbe.stay() }
    @Test func two() async throws { try await RelaySocketsProbe.stay() }
}

@Suite(.relaySockets) struct RelaySocketsProbeB {
    @Test func one() async throws { try await RelaySocketsProbe.stay() }
    @Test func two() async throws { try await RelaySocketsProbe.stay() }
}

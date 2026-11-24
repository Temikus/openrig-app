import Testing

@testable import RigClient

/// Two refreshes at once used to start two relays and lose one. Runs must not overlap, and each starts after the one
/// before ends.
@MainActor @Suite struct InOrderTests {
    @MainActor final class Log {
        var lines: [String] = []
    }

    @Test func runsNeverOverlap() async {
        let order = InOrder()
        let log = Log()
        let first = Task {
            await order.run {
                log.lines.append("start 1")
                try? await Task.sleep(for: .milliseconds(50))
                log.lines.append("end 1")
            }
        }
        let second = Task {
            await order.run {
                log.lines.append("start 2")
                log.lines.append("end 2")
            }
        }
        await first.value
        await second.value
        #expect(
            log.lines == ["start 1", "end 1", "start 2", "end 2"]
                || log.lines == ["start 2", "end 2", "start 1", "end 1"])
    }
}

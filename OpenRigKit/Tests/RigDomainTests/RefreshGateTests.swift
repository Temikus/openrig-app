import Testing

@testable import RigDomain

private let t0 = ContinuousClock.now
private func ms(_ n: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(n)) }

@Suite struct RefreshGateTests {
    @Test func nothingAskedNothingDue() {
        #expect(RefreshGate().nextStart == nil)
    }

    @Test func aBurstOfEventsIsOneRefresh() {
        var gate = RefreshGate()
        for n in stride(from: 0, through: 200, by: 20) { gate.request(.event, at: ms(n)) }
        #expect(gate.nextStart == ms(250))
        gate.start(at: ms(249))
        #expect(!gate.isRunning)
        gate.start(at: ms(250))
        #expect(gate.isRunning)
        gate.finish()
        #expect(gate.nextStart == nil)
    }

    @Test func eventRefreshesAreAtLeastTheGapApart() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.start(at: ms(250))
        #expect(gate.isRunning)
        gate.finish()
        gate.request(.event, at: ms(400))
        gate.request(.event, at: ms(1_000))
        #expect(gate.nextStart == ms(2_250))
        gate.start(at: ms(2_000))
        #expect(!gate.isRunning)
        gate.start(at: ms(2_250))
        #expect(gate.isRunning)
    }

    /// After a quiet spell the next event waits only for the merge.
    @Test func aLateEventWaitsOnlyForTheMerge() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.start(at: ms(250))
        #expect(gate.isRunning)
        gate.finish()
        gate.request(.event, at: ms(10_000))
        #expect(gate.nextStart == ms(10_250))
    }

    @Test func aRefreshNowSkipsTheMergeAndTheGap() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.start(at: ms(250))
        #expect(gate.isRunning)
        gate.finish()
        gate.request(.now, at: ms(300))
        #expect(gate.nextStart == ms(300))
        gate.start(at: ms(300))
        #expect(gate.isRunning)
    }

    /// The gap counts from any refresh, so an event right after the poll waits.
    @Test func anEventAfterARefreshNowWaitsTheGap() {
        var gate = RefreshGate()
        gate.request(.now, at: ms(0))
        gate.start(at: ms(0))
        #expect(gate.isRunning)
        gate.finish()
        gate.request(.event, at: ms(100))
        #expect(gate.nextStart == ms(2_000))
    }

    @Test func aRefreshNowServesWaitingEvents() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.request(.now, at: ms(100))
        gate.start(at: ms(100))
        #expect(gate.isRunning)
        gate.finish()
        #expect(gate.nextStart == nil)
    }

    @Test func neverTwoAtOnce() {
        var gate = RefreshGate()
        gate.request(.now, at: ms(0))
        gate.start(at: ms(0))
        #expect(gate.isRunning)
        gate.request(.now, at: ms(50))
        gate.request(.event, at: ms(60))
        #expect(gate.isRunning)
        #expect(gate.nextStart == nil)
        let second = gate.start(at: ms(5_000))
        #expect(!second)
        gate.finish()
        // One more run, at once, for everything asked during the first.
        #expect(gate.nextStart == ms(50))
        gate.start(at: ms(5_000))
        #expect(gate.isRunning)
        gate.finish()
        #expect(gate.nextStart == nil)
    }

    @Test func anEventDuringARefreshRunsOnceMoreAfterTheGap() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.start(at: ms(250))
        #expect(gate.isRunning)
        gate.request(.event, at: ms(300))
        gate.request(.event, at: ms(900))
        gate.finish()
        #expect(gate.nextStart == ms(2_250))
    }

    /// A store that wakes late still starts: what is due stays due.
    @Test func aLateWakeStillStarts() {
        var gate = RefreshGate()
        gate.request(.event, at: ms(0))
        gate.start(at: ms(60_000))
        #expect(gate.isRunning)
    }
}

/// Decides when a store's next refresh may start. It holds no timers: the store sleeps until `nextStart`,
/// then calls `start(at:)`, refreshes, and calls `finish()`.
///
/// - An event refresh starts `merge` after the first event, so a burst is one refresh.
/// - It starts no sooner than `gap` after the last refresh of any kind started.
/// - A refresh `.now` (the person's own action, the safety poll) skips both waits.
/// - Two refreshes never run at once. A request made during one gets one more run after it.
public struct RefreshGate: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    public enum Request: Sendable, Equatable {
        /// A daemon event: merged with others and held to the gap.
        case event
        /// The person's action or the safety poll.
        case now
    }

    public var merge: Duration
    public var gap: Duration
    public private(set) var isRunning = false
    private var lastStart: Instant?
    /// The first event since the last start, if any.
    private var eventSince: Instant?
    /// When a refresh `.now` was first asked for since the last start, if any.
    private var nowSince: Instant?

    public init(merge: Duration = .milliseconds(250), gap: Duration = .seconds(2)) {
        self.merge = merge
        self.gap = gap
    }

    public mutating func request(_ request: Request, at time: Instant) {
        switch request {
        case .event: if eventSince == nil { eventSince = time }
        case .now: if nowSince == nil { nowSince = time }
        }
    }

    /// When the next refresh may start. Nil while one runs or when nothing is waiting.
    public var nextStart: Instant? {
        guard !isRunning else { return nil }
        if let nowSince { return nowSince }
        guard let eventSince else { return nil }
        let merged = eventSince.advanced(by: merge)
        guard let lastStart else { return merged }
        return max(merged, lastStart.advanced(by: gap))
    }

    /// Marks a refresh started if one is due at `time`. It serves every request made before it.
    @discardableResult
    public mutating func start(at time: Instant) -> Bool {
        guard let due = nextStart, due <= time else { return false }
        isRunning = true
        lastStart = time
        eventSince = nil
        nowSince = nil
        return true
    }

    public mutating func finish() {
        isRunning = false
    }
}

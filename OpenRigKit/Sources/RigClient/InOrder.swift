/// Runs async work one piece at a time, in the order asked: each run waits for the one before it to finish. For work
/// that must not overlap with itself, such as starting or stopping the relay.
@MainActor public final class InOrder {
    private var last: Task<Void, Never>?

    public init() {}

    public func run(_ work: @escaping @MainActor () async -> Void) async {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        last = task
        await task.value
    }
}

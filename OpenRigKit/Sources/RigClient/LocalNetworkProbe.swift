import Foundation
import Network
import Synchronization

/// Whether iOS refused this app Local Network access, asked by opening a TCP connection to `endpoint`. A
/// refused app's connection waits with `localNetworkDenied`; any other result, or none within `timeout`, is false.
/// On a first run this connection is also what makes iOS ask the person.
public func localNetworkDenied(_ endpoint: RemoteEndpoint, timeout: Duration = .seconds(2)) async -> Bool {
    guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else { return false }
    let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    let answered = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let finish: @Sendable (Bool) -> Void = { denied in
            let first = answered.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            connection.cancel()
            continuation.resume(returning: denied)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .waiting: finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
            case .ready, .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: .global())
        Task {
            try? await Task.sleep(for: timeout)
            finish(false)
        }
    }
}

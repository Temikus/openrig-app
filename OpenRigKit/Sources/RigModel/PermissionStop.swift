import Foundation

/// `permission_stop` from `GET /api/seat/status/:seat`: a Claude Code permission prompt seen through
/// its hooks. The daemon calls it an expiring diagnostic, so it is re-read before every answer.
public struct PermissionStop: Decodable, Sendable, Equatable {
    public var state: PermissionStopState
    /// The command the agent wants to run. Shown in full: truncating it could hide the risky part.
    public var command: String?
    public var observedAt: Date?
    /// "main" or "subagent".
    public var actor: String?

    public init(state: PermissionStopState, command: String? = nil, observedAt: Date? = nil, actor: String? = nil) {
        self.state = state
        self.command = command
        self.observedAt = observedAt
        self.actor = actor
    }

    public static let unavailable = PermissionStop(state: .unavailable)

    private enum CodingKeys: String, CodingKey {
        case state, command, actor
        case observedAt = "observed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(PermissionStopState.self, .state) ?? .unavailable
        let raw = c.lenient(String.self, .command)
        command = raw == "unavailable" ? nil : raw
        observedAt = c.lenient(String.self, .observedAt).flatMap(parseDaemonDate)
        actor = c.lenient(String.self, .actor)
    }
}

public struct PermissionStopState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let unavailable = PermissionStopState(rawValue: "unavailable")
    /// A prompt is on screen, waiting for an answer.
    public static let requestObserved = PermissionStopState(rawValue: "request_observed")
    public static let completed = PermissionStopState(rawValue: "completed")
}

/// The slice of `GET /api/seat/status/:seat` the app uses.
public struct SeatStatusReport: Decodable, Sendable, Equatable {
    public var permissionStop: PermissionStop
    /// The folder the seat was launched in: a row's relative paths resolve against its source seat's.
    public var launchCwd: String?

    public init(permissionStop: PermissionStop, launchCwd: String? = nil) {
        self.permissionStop = permissionStop
        self.launchCwd = launchCwd
    }

    private enum CodingKeys: String, CodingKey {
        case permissionStop = "permission_stop"
        case launchCwd = "launch_cwd"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionStop = c.lenient(PermissionStop.self, .permissionStop) ?? .unavailable
        launchCwd = c.lenient(String.self, .launchCwd)
    }
}

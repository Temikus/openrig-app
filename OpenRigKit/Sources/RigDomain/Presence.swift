import RigModel

/// Whether a seat's agent is there to talk to.
public enum SeatPresence: Equatable, Sendable {
    case live
    /// Launching: the daemon hasn't seen the harness ready yet.
    case starting
    /// The tmux session vanished without a stop: a crash, a killed pane, a reboot.
    case lost
    /// The session exited. The daemon doesn't say whether that was on purpose.
    case exited
    /// The launch failed.
    case failed

    /// Down and not by request, so a person has to bring it back.
    public var needsYou: Bool { self == .lost || self == .failed }
}

/// The daemon keeps `status: running` until its reconciler runs; `session_missing` shows up at once.
/// A launching seat can briefly look lost before its session exists, so `pending` wins.
public func presence(_ seat: Seat) -> SeatPresence {
    if seat.startupStatus == "pending" { return .starting }
    if seat.status == .detached || seat.activity?.reason == "session_missing" { return .lost }
    if seat.status == .failed || seat.startupStatus == "failed" { return .failed }
    if seat.status == .exited { return .exited }
    return .live
}

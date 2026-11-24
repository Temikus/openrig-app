import Foundation

/// What happened after Allow once or Decline, from `RelayDeskClient`'s result.
public enum PromptOutcome: Equatable, Sendable {
    case allowed
    case declined(withNote: Bool)
    /// The reply was lost, and a resend found the prompt gone: the answer almost surely went through.
    case probablyAnswered
    /// As above, and the seat now asks something else.
    case answeredThenNewPrompt
    /// The seat asks something else now. Nothing was sent.
    case changed
    /// Nothing waits on the seat any more. Nothing was sent from this phone; who answered isn't known.
    case gone
    /// The Mac can't read this prompt's plain Yes, or its No: answer in the terminal.
    case cannotAllowOnce
    case cannotDecline
    /// The answer went out, but its reply was lost. It may have been done.
    case lostReply
    /// Nothing was sent: the Mac couldn't be reached.
    case unreachable
    case failed(String)

    public enum Action: Sendable, Equatable {
        case allowOnce
        case decline(reason: String)
    }

    public init(_ action: Action, _ result: Result<Void, RelayDeskError>) {
        switch result {
        case .success:
            switch action {
            case .allowOnce: self = .allowed
            case .decline(let reason):
                self = .declined(withNote: !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .failure(let error):
            switch error {
            case .probablyAnswered: self = .probablyAnswered
            case .answeredThenNewPrompt: self = .answeredThenNewPrompt
            case .promptChanged: self = .changed
            // A row no longer waiting on the person reads the same as a prompt gone.
            case .promptGone, .notForYou: self = .gone
            case .cannotAllowOnce: self = .cannotAllowOnce
            case .cannotDecline: self = .cannotDecline
            case .lostReply: self = .lostReply
            case .unreachable, .cancelled: self = .unreachable
            case .actorMismatch(let who): self = .failed(who)
            case .targetNeedsInput, .refused: self = .failed("The Mac refused it.")
            case .notFound(let message), .failed(let message), .decoding(let message): self = .failed(message)
            }
        }
    }

    /// Only an answer that never left the phone can be tried again. Anything that may have gone through can't, so
    /// a second tap never answers a later prompt.
    public var keepsButtons: Bool { self == .unreachable }

    /// The seat asks something else now: offer to show it, never swap it in under the person's thumb.
    public var offersNewPrompt: Bool { self == .changed || self == .answeredThenNewPrompt }
}

/// A fresh read of the prompt on screen, compared with what was shown.
public enum PromptCheck: Equatable, Sendable {
    case same
    case changed(RelayPrompt)
    case gone
    /// The read failed: nothing is known.
    case unknown

    public init(shown: RelayPrompt, now: Result<RelayPrompt, RelayDeskError>) {
        switch now {
        case .success(let prompt):
            self = prompt.command == shown.command && prompt.observedAt == shown.observedAt ? .same : .changed(prompt)
        case .failure(.promptGone), .failure(.notForYou), .failure(.notFound): self = .gone
        case .failure: self = .unknown
        }
    }
}

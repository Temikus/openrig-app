import Foundation
import RigModel

/// What the phone's Rigs tab and seat screen say about a seat. The views only lay these out.
extension RelaySeat {
    /// The seat's colour on the phone, as on the Mac: green working, coral needs you, grey idle.
    public enum Look: Sendable, Equatable {
        case working, idle, needsYou, down, unknown
    }

    /// Not running means the seat can't act, so that wins; then a prompt; then the daemon's activity.
    public var look: Look {
        guard state == "running" else { return .down }
        if atPrompt { return .needsYou }
        switch activity {
        case "running": return .working
        case "idle": return .idle
        case "needs_input": return .needsYou
        default: return .unknown
        }
    }

    /// The line under the seat's name, e.g. "working" or "down · exited".
    public var statusWords: String {
        switch look {
        case .down: "down · \(state)"
        case .needsYou: atPrompt ? "stopped at a prompt" : "needs input"
        case .working: "working"
        case .idle: "idle"
        case .unknown: state
        }
    }

    public var queueWords: String {
        guard active > 0 else { return "nothing waiting" }
        return blocked > 0 ? "\(active) open · \(blocked) blocked" : "\(active) open"
    }

    public var contextWords: String? {
        contextUsed.map { "\(Int(($0 * 100).rounded()))%" }
    }

    /// Why Message is off. A queued task waits for the seat either way, so Queue a task stays on.
    public enum MessageBlock: Sendable, Equatable {
        /// `rig send` refuses a seat at a prompt with `target_needs_input`.
        case atPrompt
        /// Nothing runs to type into.
        case down
    }

    public var messageBlocked: MessageBlock? {
        if look == .down { return .down }
        return atPrompt ? .atPrompt : nil
    }

    public var messageBlockedWords: String? {
        switch messageBlocked {
        case .atPrompt: "A message can't reach a seat that is stopped at a prompt. Answer the prompt first."
        case .down: "\(name) isn't running, so a message has nowhere to go. Queue a task: it waits for the seat."
        case nil: nil
        }
    }

    /// The composer's words when the seat changes while the person types. The draft stays either way.
    public var composerBlockedWords: String? {
        switch messageBlocked {
        case .atPrompt:
            "\(name) stopped at a prompt, so this can't be sent yet. It's kept here: send it once the prompt is answered, or queue it as a task."
        case .down:
            "\(name) stopped running, so this can't be sent. It's kept here; a queued task would wait for the seat."
        case nil: nil
        }
    }

    /// A rig's line under its name, e.g. "7 seats · 2 working · 2 at a prompt".
    public static func summary(_ seats: [RelaySeat]) -> String {
        var parts = [seats.count == 1 ? "1 seat" : "\(seats.count) seats"]
        let working = seats.count { $0.look == .working }
        let prompts = seats.count { $0.look == .needsYou }
        let down = seats.count { $0.look == .down }
        if working > 0 { parts.append("\(working) working") }
        if prompts > 0 { parts.append(prompts == 1 ? "1 at a prompt" : "\(prompts) at a prompt") }
        if down > 0 { parts.append("\(down) down") }
        if parts.count == 1 { parts.append("nothing running") }
        return parts.joined(separator: " · ")
    }
}

/// A message or a task from the phone, and what to say after it.
public struct RemoteSend: Sendable, Equatable {
    public var done: String
    /// "sent" or "queued", for the words when it's unclear.
    var verb: String
    var noun: String

    public static func message(to name: String) -> RemoteSend {
        RemoteSend(done: "Message sent to \(name).", verb: "sent", noun: "The message")
    }

    public static func task(for name: String) -> RemoteSend {
        RemoteSend(done: "Task queued for \(name).", verb: "queued", noun: "The task")
    }

    /// The error in plain words. Says whether it went out, since the person decides from that whether to try again.
    public func words(for error: RelayDeskError) -> String {
        switch error {
        case .lostReply:
            "\(noun) may have been \(verb): the Mac didn't confirm it. Check on the Mac before trying again."
        case .unreachable:
            "\(noun) was not \(verb): the phone can't reach the Mac."
        case .targetNeedsInput:
            "The seat stopped at a prompt, so the message wasn't sent. Answer the prompt first."
        case .actorMismatch(let message), .notFound(let message):
            message
        case .failed(let message):
            "The Mac couldn't do it: \(message)"
        case .refused:
            "The Mac refused this. Update OpenRig on the Mac."
        case .decoding:
            "The Mac's answer didn't make sense. Update OpenRig on the Mac or the phone."
        case .cancelled:
            "\(noun) was not \(verb)."
        case .notForYou, .promptGone, .promptChanged, .cannotAllowOnce, .cannotDecline, .probablyAnswered,
            .answeredThenNewPrompt:
            "The Mac refused this."
        }
    }
}

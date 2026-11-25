import Foundation

/// Preflight's messages as New Rig shows them: one row per thing to know, naming the seats it applies to.
///
/// OpenRig reports each check once per seat ("orch.lead: …", "review.r1: …"), and says some things twice in other
/// words, so a three-seat template gave nine lines. Messages it is known to send get plain words; any other message
/// is shown as OpenRig wrote it, grouped with identical ones.
public struct PreflightNote: Sendable, Equatable, Identifiable {
    /// What the person reads.
    public var text: String
    /// The seats it is about, as their member names ("lead", "r1"), with the model where it names one.
    public var seats: [String]
    /// OpenRig's own messages behind it, once each without the seat prefix, for a tooltip.
    public var detail: [String]

    public var id: String { text }

    public static func group(_ messages: [String], seats ids: [String]) -> [PreflightNote] {
        var notes: [PreflightNote] = []
        for message in messages {
            let (seat, body) = split(message, ids: ids)
            var (text, label) = (body, seat.map(member))
            if let match = body.firstMatch(of: /configured model '([^']+)' is unverified/) {
                text = modelUnchecked
                label = label.map { "\($0) (\(match.output.1))" }
            } else if body.hasPrefix("permission_policy absent") || body.hasPrefix("no permission policy") {
                text = noPolicy
            }
            if let i = notes.firstIndex(where: { $0.text == text }) {
                if let label, !notes[i].seats.contains(label) { notes[i].seats.append(label) }
                if !notes[i].detail.contains(body) { notes[i].detail.append(body) }
            } else {
                notes.append(PreflightNote(text: text, seats: label.map { [$0] } ?? [], detail: [body]))
            }
        }
        return notes
    }

    static let modelUnchecked =
        "Models aren't checked before launch. OpenRig makes no model call, so a model your account can't use "
        + "only shows when the seat starts."
    static let noPolicy =
        "No permission policy, so these seats start with the team default's allowances."

    /// "review.r1: text" → ("review.r1", "text") when the prefix is one of the spec's seats.
    private static func split(_ message: String, ids: [String]) -> (String?, String) {
        for id in ids where message.hasPrefix(id + ": ") {
            return (id, String(message.dropFirst(id.count + 2)))
        }
        return (nil, message)
    }

    private static func member(_ id: String) -> String {
        id.split(separator: ".", maxSplits: 1).last.map(String.init) ?? id
    }
}

/// The words for the confirmation before the phone forgets its pairing. At large text sizes an alert cuts its
/// message, so when answers would be dropped, the title says so.
public struct UnpairWording: Equatable, Sendable {
    public enum Kind: Sendable { case pairAgain, unpair }

    public var title: String
    public var message: String
    public var confirm: String

    public init(_ kind: Kind, mac: String, unsent: Int) {
        let answers = unsent == 1 ? "1 unsent answer" : "\(unsent) unsent answers"
        let tail =
            "You'll need a new code from the Mac. \(mac) still lists this phone until you unpair it there, under Settings › Phone."
        switch kind {
        case .pairAgain:
            title = unsent > 0 ? "Drop \(answers) and pair again?" : "Forget \(mac) and pair again?"
            confirm = "Forget and Pair Again"
        case .unpair:
            title = unsent > 0 ? "Drop \(answers) and unpair?" : "Unpair this phone?"
            confirm = "Unpair"
        }
        let reached = unsent == 1 ? "It hasn't reached \(mac). " : "They haven't reached \(mac). "
        message = unsent > 0 ? reached + tail : tail
    }
}

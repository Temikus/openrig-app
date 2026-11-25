/// The person using the app, as OpenRig addresses them.
public enum Human {
    /// "The unnamed person at the terminal". Not `operator-human@kernel`: that seat is the TUI's own pane, so an agent
    /// replying to it types into the TUI. Sent from a human address, a message tells the agent to reply with a queue row.
    public static let session = "human@host"

    /// Who the app acts as: the gateway's default person when one is registered, else the unnamed person. Replies to
    /// `human@host` have no wake route, so the daemon's stuck sweep pings the sender about each one.
    public static func address(in gateway: GatewayParticipants?) -> String {
        gateway?.defaultAddress ?? session
    }

    /// The unnamed person's addresses: the daemon accepts `human@kernel` for `human@host`, and older rows use either.
    public static let unnamed = [session, "human@kernel"]

    /// Where rows for the person arrive: who the app acts as, then the unnamed person's addresses. The daemon keeps a
    /// destination as the sender wrote it, so each is read separately.
    public static func addresses(of me: String) -> [String] {
        [me] + unnamed.filter { $0 != me }
    }

    public static func isYou(_ session: String) -> Bool {
        unnamed.contains(session)
    }

    /// The daemon's human addresses: `human@host`, `human@kernel`, and `human-<name>@` either.
    public static func isAddress(_ session: String) -> Bool {
        session.wholeMatch(of: /human(?:-[A-Za-z0-9._-]+)?@(?:host|kernel)/) != nil
    }
}

import Foundation

/// A Claude Code permission prompt read off the pane. The daemon reports the command as
/// "Bash: details withheld", so the screen is the only place the user can see what would run.
public struct PromptScreen: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var number: Int
        public var text: String
    }

    /// e.g. "Bash command".
    public var title: String
    /// The agent's one-line reason, when shown.
    public var description: String?
    /// The command as displayed (terminal-wrapped lines joined with newlines).
    public var command: String
    public var options: [Option]
    /// Where the prompt sits on the pane: its top rule through its footer, as screen rows.
    public var rows: ClosedRange<Int>

    /// The key for a plain "Yes": the first option whose text is exactly "Yes".
    /// Nil when the menu has no plain yes, so the app never guesses.
    public var allowOnceKey: String? {
        options.first { $0.text == "Yes" }.map { String($0.number) }
    }

    /// The key for a plain "No". Esc doesn't work here: typed as a character it reaches the prompt
    /// as the start of an escape sequence, not as the Esc key.
    public var declineKey: String? {
        options.first { $0.text == "No" || $0.text.hasPrefix("No,") }.map { String($0.number) }
    }

    /// The option that lets this kind of call through again without asking. Claude Code words it many
    /// ways, all seen live: "Yes, allow reading from … from this project" (this session only),
    /// "Yes, and allow access to … and … commands" (saved to the project's settings.local.json),
    /// "Yes, and always allow access to … from this project". Only "Yes, [and] [always] allow …" and
    /// "Yes, [and] don't ask again …" count: "Yes, and switch to auto mode" also starts with "Yes, ".
    public var rememberOption: Option? {
        options.first { option in
            guard let grant = Self.grant(option.text) else { return false }
            var rest = grant.lowercased()
            if rest.hasPrefix("always ") { rest.removeFirst(7) }
            return rest.hasPrefix("allow ") || rest.hasPrefix("don't ask again")
                || rest.hasPrefix("don\u{2019}t ask again")
        }
    }

    /// The remember option as a menu label, in Claude Code's words: "Always allow access to /tmp from this project".
    public var rememberLabel: String? {
        guard let text = rememberOption?.text, let grant = Self.grant(text) else { return nil }
        return grant.prefix(1).uppercased() + grant.dropFirst()
    }

    /// "Yes, and allow x" → "allow x"; nil unless the option starts with "Yes, ".
    private static func grant(_ text: String) -> Substring? {
        guard text.hasPrefix("Yes, ") else { return nil }
        let rest = text.dropFirst(5)
        return rest.hasPrefix("and ") ? rest.dropFirst(4) : rest
    }

    public init?(lines raw: [String]) {
        let lines = raw.map { strippingEscapes($0).trimmingTrailingWhitespace() }
        guard let ask = lines.lastIndex(where: { $0.contains("Do you want to proceed?") }) else { return nil }

        // Claude Code draws its own rules from column 0; everything it shows inside the box is indented
        // (" " or " │ "). Command text can draw lookalike rules but can't start them at column 0, so only
        // column-0 rules count, and any other rule-like line in the prompt makes the screen unreadable.
        // Showing part of a command while "Yes" approves all of it would be worse than no answer.
        let isDashed = { (s: String) in s.hasPrefix("╌╌╌") }
        let isRule = { (s: String) in s.hasPrefix("───") }
        let looksLikeRule = { (s: String) in s.contains("╌") || s.contains("───") || s.contains("━━━") }
        guard let headerRule = lines[..<ask].lastIndex(where: isRule) else { return nil }
        let dashed = lines.indices.filter { $0 > headerRule && $0 < ask && isDashed(lines[$0]) }
        guard dashed.count == 2 else { return nil }
        let (open, close) = (dashed[0], dashed[1])
        let others = lines.indices.filter { $0 > headerRule && $0 < ask && $0 != open && $0 != close }
        guard !others.contains(where: { looksLikeRule(lines[$0]) }) else { return nil }
        let body = lines[(open + 1)..<close]
        command =
            body
            .map { line in
                var s = Substring(line).drop { $0 == " " }
                if s.hasPrefix("│") { s = s.dropFirst().drop { $0 == " " } }
                return String(s)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // Header: the first text line after the solid rule; the description is the last line before the box.
        let headerStart = headerRule + 1
        let header = lines[headerStart..<open].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        title = header.first ?? "Permission"
        description = header.count > 1 ? header.last : nil

        // Options: "❯ 1. Yes", "  2. Yes, allow …" (continuation lines fold into the option above).
        var options: [Option] = []
        var end = ask
        for i in (ask + 1)..<lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "❯", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]) {
                options.append(Option(number: n, text: t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
                end = i
            } else if !t.isEmpty, !options.isEmpty, line.hasPrefix("      ") {
                options[options.count - 1].text += " " + t
                end = i
            } else if t.hasPrefix("Esc") {
                end = i
                break
            } else if isRule(line) {
                break
            }
        }
        self.options = options
        rows = headerRule...end
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}

extension Tmux {
    /// The visible screen of one pane, as plain text lines.
    public func screen(pane: String) async throws -> [String] {
        try await run(["capture-pane", "-p", "-t", pane]).components(separatedBy: "\n")
    }
}

extension PromptScreen {
    /// Where a question menu (Claude Code's AskUserQuestion) sits on the pane: its first line through its footer.
    /// Not a `PromptScreen`: it asks no permission, so it never pauses typing or offers Yes and No.
    ///
    /// Seen live (a 65×40 pane): a column-0 rule, "☐ <header>", the question, then "❯ 1. Option A" with its
    /// description below, "4. Type something.", another column-0 rule, "5. Chat about this", and the footer
    /// "Enter to select · ↑/↓ to navigate · Esc to cancel". So the menu ends at that footer and starts at the last
    /// column-0 rule above its first option; the rule between options 4 and 5 is below that option.
    public static func questionRows(lines raw: [String]) -> ClosedRange<Int>? {
        let lines = raw.map { strippingEscapes($0).trimmingTrailingWhitespace() }
        guard
            let footer = lines.lastIndex(where: { $0.hasPrefix("Enter to select") && $0.contains("to navigate") }),
            let first = lines[..<footer].lastIndex(where: { line in
                var t = Substring(line).drop { $0 == " " }
                if t.hasPrefix("❯") { t = t.dropFirst().drop { $0 == " " } }
                return t.hasPrefix("1. ")
            }),
            let top = lines[..<first].lastIndex(where: { $0.hasPrefix("───") })
        else { return nil }
        return top...footer
    }
}

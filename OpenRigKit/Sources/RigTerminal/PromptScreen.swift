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

    public init?(lines raw: [String]) {
        let lines = raw.map { strippingEscapes($0).trimmingTrailingWhitespace() }
        guard let ask = lines.lastIndex(where: { $0.contains("Do you want to proceed?") }) else { return nil }

        // The command sits between exactly two dashed rules, below the header's solid rule.
        // The command's own output can draw rules too, so any other count is refused: showing part
        // of a command while "Yes" approves all of it would be worse than sending the user to the pane.
        let isDashed = { (s: String) in s.trimmingCharacters(in: .whitespaces).hasPrefix("╌╌╌") }
        let isRule = { (s: String) in s.trimmingCharacters(in: .whitespaces).hasPrefix("───") }
        let headerRule = lines[..<ask].lastIndex(where: isRule) ?? -1
        let dashed = lines.indices.filter { $0 > headerRule && $0 < ask && isDashed(lines[$0]) }
        guard dashed.count == 2 else { return nil }
        let (open, close) = (dashed[0], dashed[1])
        let body = lines[(open + 1)..<close]
        guard !body.contains(where: { $0.contains("╌") || $0.contains("───") }) else { return nil }
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
        for line in lines[(ask + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "❯", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]) {
                options.append(Option(number: n, text: t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else if !t.isEmpty, !options.isEmpty, line.hasPrefix("      ") {
                options[options.count - 1].text += " " + t
            } else if t.hasPrefix("Esc") || isRule(line) {
                break
            }
        }
        self.options = options
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

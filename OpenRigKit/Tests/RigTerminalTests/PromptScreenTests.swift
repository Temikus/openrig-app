import Foundation
import Testing

@testable import RigTerminal

@Suite struct PromptScreenTests {
    func fixture() throws -> [String] {
        let url = try #require(
            Bundle.module.url(forResource: "claude-permission-prompt", withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    // Captured from a live Claude Code permission prompt on a throwaway seat (paths scrubbed).
    @Test func readsTheLiveClaudePrompt() throws {
        let screen = try #require(PromptScreen(lines: try fixture()))
        #expect(screen.title == "Bash command")
        #expect(screen.description == "Check my queue position and read the project manifest")
        #expect(screen.command.hasPrefix("rig queue whoami 2>&1 | head -20"))
        #expect(screen.command.hasSuffix("/Users/someone/.openrig/workspace/missions"))
        #expect(!screen.command.contains("│"))
        #expect(screen.options.map(\.number) == [1, 2, 3, 4])
        #expect(screen.options[0].text == "Yes")
        #expect(screen.options[3].text == "No")
    }

    @Test func picksTheOptionByMeaningNotPosition() throws {
        let screen = try #require(PromptScreen(lines: try fixture()))
        #expect(screen.allowOnceKey == "1")
        #expect(screen.declineKey == "4")
        // Option 3 here switches the seat to auto mode; it must never be what "decline" sends.
        #expect(screen.options[2].text.contains("auto mode"))
    }

    @Test func noPromptOnScreen() {
        #expect(PromptScreen(lines: ["$ ls", "file.txt", "$"]) == nil)
    }

    @Test func escapesAreIgnored() throws {
        let colored = try fixture().map { $0.isEmpty ? $0 : "\u{1B}[2m" + $0 + "\u{1B}[0m" }
        #expect(PromptScreen(lines: colored)?.title == "Bash command")
    }
}

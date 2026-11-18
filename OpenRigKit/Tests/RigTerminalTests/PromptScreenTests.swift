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

    // A command that draws its own dashed rule must not split the box: the app would show only
    // the tail of the command while "Yes" approves all of it. Refuse to read such a prompt.
    @Test func refusesABoxWithExtraRules() throws {
        var lines = try fixture()
        let open = try #require(lines.firstIndex { $0.hasPrefix("╌╌╌") })
        lines.insert(String(repeating: "╌", count: 80), at: open + 2)
        lines.insert(" rm -rf ~/important", at: open + 2)
        #expect(PromptScreen(lines: lines) == nil)
    }

    @Test func refusesBoxDrawingInsideTheCommand() throws {
        var lines = try fixture()
        let open = try #require(lines.firstIndex { $0.hasPrefix("╌╌╌") })
        lines.insert(" │ echo ╌╌╌ hidden", at: open + 1)
        #expect(PromptScreen(lines: lines) == nil)
    }

    @Test func noPromptOnScreen() {
        #expect(PromptScreen(lines: ["$ ls", "file.txt", "$"]) == nil)
    }

    @Test func escapesAreIgnored() throws {
        let colored = try fixture().map { $0.isEmpty ? $0 : "\u{1B}[2m" + $0 + "\u{1B}[0m" }
        #expect(PromptScreen(lines: colored)?.title == "Bash command")
    }
}

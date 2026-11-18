import Foundation
import Testing

@testable import RigTerminal

@Suite struct PromptScreenTests {
    func fixture(_ name: String = "claude-permission-prompt") throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
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

    // Both recorded live. Choosing option 2 on the Bash one wrote `Bash(mkdir -p …)` and `Read(//tmp/**)`
    // to the project's .claude/settings.local.json; the read one saved nothing on disk.
    @Test func remembersOnlyARuleOption() throws {
        let read = try #require(PromptScreen(lines: try fixture()))
        #expect(read.rememberOption?.number == 2)
        #expect(read.rememberOption?.text.hasSuffix("from this project") == true, "continuation line folded in")
        #expect(read.rememberLabel?.hasPrefix("Allow reading from /Users/someone/.openrig/workspace and") == true)

        let bash = try #require(PromptScreen(lines: try fixture("claude-permission-prompt-bash")))
        #expect(bash.command == "mkdir -p /tmp/openrig-apptest-probe && ls -ld /tmp/openrig-apptest-probe")
        #expect(bash.allowOnceKey == "1")
        #expect(bash.declineKey == "4")
        #expect(bash.rememberOption?.number == 2)
        #expect(bash.rememberLabel == "Allow access to /tmp and mkdir -p /tmp/openrig-apptest-probe commands")

        var lines = try fixture("claude-permission-prompt-bash")
        let two = try #require(lines.firstIndex { $0.contains("2. Yes, and allow") })
        lines[two + 1] = ""
        lines[two] = "   2. Yes, and always allow access to /tmp from this project"
        #expect(PromptScreen(lines: lines)?.rememberLabel == "Always allow access to /tmp from this project")
        lines[two] = "   2. Yes, and switch to plan mode"
        #expect(PromptScreen(lines: lines)?.rememberOption == nil, "a mode switch isn't a rule")
        lines.remove(at: two + 1)
        lines[two] = "   2. Yes, and don\u{2019}t ask again for mkdir commands in /tmp"
        #expect(PromptScreen(lines: lines)?.rememberLabel == "Don\u{2019}t ask again for mkdir commands in /tmp")

        // With no such option nothing stands in for it: not "switch to auto mode", not "Yes".
        lines.remove(at: two)
        let none = try #require(PromptScreen(lines: lines))
        #expect(none.rememberOption == nil)
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

    // A multi-line command that fakes a whole header (solid rule, title, dashed rule) inside the box.
    @Test func refusesAFakeHeaderInsideTheCommand() throws {
        var lines = try fixture()
        let open = try #require(lines.firstIndex { $0.hasPrefix("╌╌╌") })
        let fake = [
            " │ " + String(repeating: "─", count: 60), " │  Bash command", " │  Harmless listing",
            " │ " + String(repeating: "╌", count: 60), " │ ls",
        ]
        lines.insert(contentsOf: fake, at: open + 1)
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

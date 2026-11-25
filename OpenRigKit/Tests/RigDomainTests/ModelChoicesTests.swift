import Foundation
import Testing

@testable import RigDomain

@Suite struct ModelChoicesTests {
    /// Lines of `claude --help` (Claude Code, 2026-11-25).
    static let claudeHelp = """
          --effort <level>                      Effort level for the current session
                                                (low, medium, high, xhigh, max)
          --environment <environment_id>        Create a new cloud session that runs on
          --model <model>                       Model for the current session. Use an
                                                alias for the latest model (e.g.
                                                'fable', 'opus', or 'sonnet') or a
                                                model's full name.
          -n, --name <name>                     Set a display name for this session
        """

    @Test func claudeAliasesAndLevelsComeFromItsHelp() {
        let choices = ModelChoices.claude(help: Self.claudeHelp)
        #expect(choices.models.map(\.id) == ["fable", "opus", "sonnet"])
        #expect(choices.models.first?.label == "Fable")
        #expect(choices.efforts == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test func unrecognisedHelpGivesNoChoices() {
        #expect(ModelChoices.claude(help: "usage: claude") == ModelChoices())
    }

    /// Shaped like `codex debug models` (Codex, 2026-11-25), trimmed.
    static let codexCatalog = """
        {"models":[
          {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","priority":3,
           "supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"high","description":"x"}]},
          {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide","priority":1,
           "supported_reasoning_levels":[{"effort":"low","description":"x"}]},
          {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","priority":2,
           "supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"ultra","description":"x"}]}
        ]}
        """

    @Test func codexShowsTheModelsItsPickerListsInItsOrder() {
        let choices = ModelChoices.codex(catalog: Data(Self.codexCatalog.utf8))
        #expect(choices.models.map(\.id) == ["gpt-6-astra", "gpt-6-sol"])
        #expect(choices.models.map(\.label) == ["GPT-6-Astra", "GPT-6-Sol"])
        #expect(choices.efforts(for: "gpt-6-sol") == ["low", "high"])
        #expect(choices.efforts(for: nil) == ["low", "ultra", "high"])
    }

    @Test func aTemplatesOwnModelStaysPickable() {
        let choices = ModelChoices(models: [.init(id: "opus", label: "Opus")])
        #expect(choices.models(including: "claude-opus-5-5").map(\.id) == ["opus", "claude-opus-5-5"])
        #expect(choices.models(including: "opus").count == 1)
        #expect(choices.models(including: nil).count == 1)
    }
}

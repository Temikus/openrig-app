import Foundation

/// The models and effort levels a seat can pick, read from each runtime's own CLI rather than typed into the app:
/// Codex prints its model catalogue (`codex debug models`, local, no model call); Claude Code names its aliases
/// and levels in `claude --help`. Other runtimes offer only their defaults.
public struct ModelChoices: Sendable, Equatable {
    public struct Model: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        /// Levels this model accepts; empty uses the runtime's.
        public var efforts: [String]

        public init(id: String, label: String, efforts: [String] = []) {
            self.id = id
            self.label = label
            self.efforts = efforts
        }
    }

    public var models: [Model]
    public var efforts: [String]

    public init(models: [Model] = [], efforts: [String] = []) {
        self.models = models
        self.efforts = efforts
    }

    /// Levels for `model` (nil: the role default).
    public func efforts(for model: String?) -> [String] {
        models.first { $0.id == model }.map(\.efforts).flatMap { $0.isEmpty ? nil : $0 } ?? efforts
    }

    /// The listed models, plus `current` when the template names one the runtime doesn't list.
    public func models(including current: String?) -> [Model] {
        guard let current, !models.contains(where: { $0.id == current }) else { return models }
        return models + [Model(id: current, label: current)]
    }

    /// A model ID typed under "Other…", written to the spec as it is: Claude Code's help lists only aliases, so this
    /// is how to pin a version. Nil for blank.
    public static func typed(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// What "Role default" means for a seat: the role's model, else the runtime's own default. A stub or terminal
    /// seat runs no model, so there's nothing to name.
    public static func roleDefault(model: String?, runtime: String) -> String {
        if model == nil, ["stub", Runtime.terminal].contains(runtime) { return "Role default" }
        return "Role default (\(model ?? "\(Runtime.label(runtime))'s default"))"
    }

    /// `codex debug models`: the models it shows in its own picker (`visibility: list`), in its order.
    public static func codex(catalog data: Data) -> ModelChoices {
        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Level: Decodable { var effort: String }
                var slug: String
                var displayName: String?
                var visibility: String?
                var priority: Int?
                var supportedReasoningLevels: [Level]?
            }
            var models: [Entry]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let catalog = try? decoder.decode(Catalog.self, from: data) else { return ModelChoices() }
        let shown = catalog.models.filter { $0.visibility == "list" }.sorted {
            ($0.priority ?? .max) < ($1.priority ?? .max)
        }
        var efforts: [String] = []
        for level in shown.flatMap({ $0.supportedReasoningLevels ?? [] }) where !efforts.contains(level.effort) {
            efforts.append(level.effort)
        }
        return ModelChoices(
            models: shown.map {
                Model(
                    id: $0.slug, label: $0.displayName ?? $0.slug,
                    efforts: ($0.supportedReasoningLevels ?? []).map(\.effort))
            },
            efforts: efforts)
    }

    /// `claude --help`: the aliases quoted under `--model` ("'fable', 'opus', or 'sonnet'") and the levels in
    /// parentheses under `--effort`.
    public static func claude(help: String) -> ModelChoices {
        func paragraph(_ flag: String) -> String {
            let lines = help.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(flag) })
            else { return "" }
            // The option's own lines: the first, then those indented past the option column.
            var text = [lines[start]]
            for line in lines[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { break }
                text.append(trimmed)
            }
            return text.joined(separator: " ")
        }
        let aliases = paragraph("--model <").matches(of: /'([a-z][a-z0-9.-]*)'/).map { String($0.output.1) }
        let levels =
            paragraph("--effort <").firstMatch(of: /\(([a-z, ]+)\)/).map {
                $0.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? []
        return ModelChoices(
            models: aliases.map { Model(id: $0, label: $0.prefix(1).uppercased() + $0.dropFirst()) }, efforts: levels)
    }
}

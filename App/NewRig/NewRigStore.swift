import AppKit
import Foundation
import Observation
import RigClient
import RigDomain
import RigModel

/// New Rig: pick a folder, a name and a template; tune the seats; review the spec, then save it to the library
/// and `rig up` it. Everything goes through the `rig` CLI, so a rig built here is the same as one built by hand.
@MainActor @Observable
final class NewRigStore {
    enum Step: Int, CaseIterable, Identifiable {
        case start, seats, review
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .start: "Start"
            case .seats: "Seats"
            case .review: "Review"
            }
        }
    }

    /// A library spec offered as a starting point.
    struct Template: Identifiable {
        var entry: SpecEntry
        var draft: RigDraft
        /// The spec file.
        var path: URL
        var id: SpecEntry.ID { entry.id }
    }

    /// `rig spec preflight --json`, plus the checks only the app can make (the name is free).
    struct Preflight: Equatable {
        var errors: [String] = []
        var warnings: [String] = []
        var ready: Bool { errors.isEmpty }
    }

    var step = Step.start
    var folder: URL? {
        didSet { if !nameEdited, let folder { name = Self.suggestedName(folder.lastPathComponent) } }
    }
    var name = "" {
        didSet { draft?.name = name }
    }
    /// Once the person types a name, picking another folder leaves it alone.
    var nameEdited = false
    private(set) var templates: [Template] = []
    private(set) var loadError: String?
    private(set) var loading = true
    private(set) var pickedID: Template.ID?
    var draft: RigDraft?
    /// Each runtime's models and effort levels, read from its own CLI.
    private(set) var choices: [String: ModelChoices] = [:]
    private(set) var roles: [RigDraft.Seat.ID: String] = [:]

    private(set) var yaml = ""
    private(set) var preflight: Preflight?
    /// The spec folder as it will be added: the template's files plus the new rig.yaml.
    private(set) var staged: URL?
    /// Set once `rig specs add` succeeded, so a retried launch doesn't add it twice.
    private(set) var savedSpec: URL?

    static let actionKey = "newrig"

    private let client: DaemonHTTP
    private let actions: ActionStore
    private let openRigHome: URL
    private let existingRigs: Set<String>
    private let shellPath: [String]
    /// Called with the rig's name once `rig up` has started it.
    private let launched: (String) async -> Void

    init(
        client: DaemonHTTP, actions: ActionStore, openRigHome: URL, existingRigs: Set<String>, shellPath: [String],
        launched: @escaping (String) async -> Void
    ) {
        self.client = client
        self.actions = actions
        self.openRigHome = openRigHome
        self.existingRigs = existingRigs
        self.shellPath = shellPath
        self.launched = launched
        actions.clear(Self.actionKey)
    }

    var picked: Template? { templates.first { $0.id == pickedID } }
    var specsRoot: URL { openRigHome.appending(path: "specs") }
    /// Where `rig specs add` puts the folder.
    var destination: URL { specsRoot.appending(path: name) }

    // MARK: Start

    func load() async {
        loading = true
        defer { loading = false }
        do {
            // A managed app starts services, and the built-in kernel says it is a preview of the running kernel,
            // not a team to start: neither is a starting point for a new rig.
            let entries = try await client.rigSpecs().filter {
                $0.hasServices != true && !($0.isBuiltin && $0.name == "kernel")
            }
            let client = client
            let reviews = await withTaskGroup(of: (SpecEntry.ID, SpecReview?).self) { group in
                for entry in entries { group.addTask { (entry.id, try? await client.specReview(id: entry.id)) } }
                var found: [SpecEntry.ID: SpecReview] = [:]
                for await (id, review) in group { found[id] = review }
                return found
            }
            templates = entries.compactMap { entry in
                guard let review = reviews[entry.id] ?? nil else { return nil }
                let path = URL(filePath: review.sourcePath)
                guard let draft = try? RigDraft(template: review.raw, folder: path.deletingLastPathComponent().path)
                else { return nil }
                return Template(entry: entry, draft: draft, path: path)
            }
            // Built-in first, in the library's order, then the person's own.
            .sorted { $0.entry.isBuiltin && !$1.entry.isBuiltin }
            loadError = templates.isEmpty ? "No rig specs in the library." : nil
        } catch {
            loadError = error.userMessage
        }
        await loadChoices()
    }

    func pick(_ template: Template) {
        pickedID = template.id
        var draft = template.draft
        draft.name = name
        self.draft = draft
        roles = Dictionary(uniqueKeysWithValues: draft.seats.map { ($0.id, draft.roleName($0)) })
    }

    /// What's missing before Continue, said under the button. Nil when Start is complete.
    var startProblem: String? {
        if folder == nil { return "Choose the project folder." }
        if let problem = Self.nameProblem(name) { return problem }
        if existingRigs.contains(name) { return "A rig named \(name) already exists." }
        if picked == nil { return "Pick a template." }
        return nil
    }

    /// Rig names become session addresses (seat@rig) and the spec's folder name.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Name the rig." }
        if name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*/) == nil {
            return "Use letters, digits, - and _ in the name, starting with a letter or digit."
        }
        return nil
    }

    /// A folder name as a rig name: "Payments Service" → "payments-service".
    static func suggestedName(_ folder: String) -> String {
        let words = folder.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return words.joined(separator: "-").filter(\.isASCII)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "The folder the rig's seats work in"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    // MARK: Seats

    private func loadChoices() async {
        async let claude = Self.output(of: "claude", ["--help"], shellPath: shellPath)
        async let codex = Self.output(of: "codex", ["debug", "models"], shellPath: shellPath)
        if let help = await claude {
            choices["claude-code"] = ModelChoices.claude(help: String(decoding: help, as: UTF8.self))
        }
        if let catalog = await codex { choices["codex"] = ModelChoices.codex(catalog: catalog) }
    }

    private nonisolated static func output(of tool: String, _ arguments: [String], shellPath: [String]) async -> Data? {
        let paths = ToolLocator.searchPaths(
            for: tool, shellPath: shellPath, fallback: ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"])
        guard let found = ToolLocator.resolve(override: nil, searchPaths: paths) else { return nil }
        return await ToolLocator.output(of: found.url, arguments: arguments, path: shellPath, timeout: .seconds(10))
    }

    func choices(for runtime: String) -> ModelChoices { choices[runtime] ?? ModelChoices() }

    /// Runtime changes keep a model only when the new runtime lists it.
    func setRuntime(_ runtime: String, for id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }) else { return }
        draft?.seats[i].runtime = runtime
        let listed = choices(for: runtime)
        if let model = draft?.seats[i].model, !listed.models.contains(where: { $0.id == model }) {
            draft?.seats[i].model = nil
        }
        if let effort = draft?.seats[i].effort, !listed.efforts(for: draft?.seats[i].model).contains(effort) {
            draft?.seats[i].effort = nil
        }
    }

    /// A model change drops an effort the new model doesn't accept.
    func setModel(_ model: String?, for id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }), let seat = draft?.seats[i] else { return }
        draft?.seats[i].model = model
        if let effort = seat.effort, !choices(for: seat.runtime).efforts(for: model).contains(effort) {
            draft?.seats[i].effort = nil
        }
    }

    func setEffort(_ effort: String?, for id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }) else { return }
        draft?.seats[i].effort = effort
    }

    func remove(_ id: RigDraft.Seat.ID) { draft?.remove(id) }

    var seatsProblem: String? { draft?.seats.isEmpty == false ? nil : "A rig needs at least one seat." }

    // MARK: Review

    /// Writes the spec folder and runs preflight on it: what Launch would add is what was checked.
    func review() async {
        guard let draft, let template = picked else { return }
        preflight = nil
        do {
            yaml = try draft.yaml()
            staged = try stage(yaml, from: template)
        } catch {
            preflight = Preflight(errors: ["Couldn't write the spec: \(error.localizedDescription)"])
            return
        }
        var result = Preflight()
        if savedSpec == nil, FileManager.default.fileExists(atPath: destination.path) {
            result.errors.append("\(destination.path) already exists. Pick another rig name, or remove that spec.")
        }
        guard let cli = actions.cli, let staged else {
            result.errors.append("rig not found. Pick it in Settings › Connection.")
            preflight = result
            return
        }
        let spec = staged.appending(path: "rig.yaml").path
        if let out = try? await cli.run(arguments: ["spec", "preflight", spec, "--json"]),
            let report = try? JSONDecoder().decode(PreflightReport.self, from: Data(out.stdout.utf8))
        {
            result.errors += report.errors
            result.warnings += report.warnings
        } else {
            result.errors.append("rig spec preflight didn't answer.")
        }
        preflight = result
    }

    private struct PreflightReport: Decodable {
        var errors: [String]
        var warnings: [String]
    }

    /// A fresh folder named after the rig, holding the template folder's files (its culture and guidance, which
    /// relative paths name) and the new rig.yaml. A template that is a lone file at the top of the person's library
    /// gets only its rig.yaml: its folder is the whole library.
    private func stage(_ yaml: String, from template: Template) throws -> URL {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appending(path: "OpenRig-NewRig-\(UUID().uuidString)")
        let folder = parent.appending(path: name)
        let source = template.path.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if source.standardizedFileURL != specsRoot.standardizedFileURL {
            try fm.copyItem(at: source, to: folder)
            for file in try fm.contentsOfDirectory(atPath: folder.path)
            where file.hasSuffix(".yaml") || file.hasSuffix(".yml") {
                if file.hasPrefix("rig.") { try fm.removeItem(at: folder.appending(path: file)) }
            }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try yaml.write(to: folder.appending(path: "rig.yaml"), atomically: true, encoding: .utf8)
        if let old = staged { try? fm.removeItem(at: old.deletingLastPathComponent()) }
        return folder
    }

    /// The two commands Launch runs, with full paths: a quoted "~" wouldn't expand if pasted into a shell.
    var addCommand: String { RigAction.addSpec(folder: (staged ?? destination).path).userCommand }
    var upCommand: String {
        RigAction.launchSpec(path: destination.appending(path: "rig.yaml").path, cwd: (folder ?? destination).path)
            .userCommand
    }

    var isLaunching: Bool { actions.isRunning(Self.actionKey) }

    /// `rig specs add`, then `rig up` on the saved spec. True once the rig is starting.
    func launch() async -> Bool {
        guard let staged, let folder, preflight?.ready == true else { return false }
        if savedSpec == nil {
            guard
                let added = await actions.result(
                    of: .addSpec(folder: staged.path), key: Self.actionKey, success: "Saved \(name) to your library")
            else { return false }
            struct Added: Decodable { var path: String? }
            let path = (try? JSONDecoder().decode(Added.self, from: Data(added.stdout.utf8)))?.path
            savedSpec = path.map { URL(filePath: $0) } ?? destination
        }
        guard let savedSpec else { return false }
        let up = RigAction.launchSpec(path: savedSpec.appending(path: "rig.yaml").path, cwd: folder.path)
        guard await actions.perform(up, key: Self.actionKey, success: "Starting \(name)'s seats") else { return false }
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        await launched(name)
        return true
    }
}
extension NewRigStore: Identifiable {}

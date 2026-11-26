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
    /// The project folder. Until the spec is saved, an untyped name follows it; after, the name is fixed.
    var folder: URL? {
        didSet {
            guard let folder else { return }
            draft?.cwd = folder.path
            name = RigName.afterPicking(
                folder: folder.lastPathComponent, current: name, typed: nameEdited, saved: savedSpec != nil)
        }
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
    /// "Blank rig": no template, every seat added.
    private(set) var startsBlank = false
    /// The roles a seat can take, from the library's agent specs.
    private(set) var roleLibrary: [Role] = []
    /// Edges and names for added seats, learned from the templates.
    private(set) var edgeRules = EdgeRules(learningFrom: [])
    var draft: RigDraft?
    /// Each runtime's models and effort levels, read from its own CLI.
    private(set) var choices: [String: ModelChoices] = [:]
    private(set) var roles: [RigDraft.Seat.ID: String] = [:]
    /// What each seat's role sets when the spec names no model, from its agent spec.
    private(set) var roleDefaults: [RigDraft.Seat.ID: RoleDefault] = [:]

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
            edgeRules = EdgeRules(learningFrom: templates.map(\.draft))
            loadError = templates.isEmpty ? "No rig specs in the library." : nil
        } catch {
            loadError = error.userMessage
        }
        await loadRoles()
        await loadChoices()
    }

    /// Agent specs with a default profile, built-in first, by name.
    private func loadRoles() async {
        guard let entries = try? await client.agentSpecs() else { return }
        roleLibrary = entries.compactMap { Role.load(agentSpec: URL(filePath: $0.sourcePath), summary: $0.summary) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // OpenRig's shared resources, which the built-in roles import and a new role imports too.
        sharedRoleFolder =
            entries.first { $0.isBuiltin && $0.name == "shared" }
            .map { URL(filePath: $0.sourcePath).deletingLastPathComponent().resolvingSymlinksInPath() }
    }

    // MARK: New role

    /// Opens New role, from Add Seat or a seat's detail.
    var makingRole = false
    /// OpenRig's shared agent spec folder (its skill pool), once the library is read.
    private(set) var sharedRoleFolder: URL?
    /// The managed skill catalog `rig skill loadout` reads.
    var skillCatalog: URL { openRigHome.appending(path: "skills") }
    /// The folders already in the person's spec library: a new role can't take one's name.
    var specFolderNames: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: specsRoot.path)) ?? [])
    }
    /// The kernel rig, whose lead drafts new roles.
    var kernelExists: Bool { existingRigs.contains("kernel") }

    /// The role just saved at `saved` (its folder, or its agent.yaml), once the library lists it.
    func addedRole(at saved: URL) async -> Role? {
        let folder = saved.pathExtension.isEmpty ? saved : saved.deletingLastPathComponent()
        let want = Role.plain(folder.resolvingSymlinksInPath().path(percentEncoded: false))
        for attempt in 0..<5 {
            await loadRoles()
            if let role = roleLibrary.first(where: { $0.folder == want }) { return role }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return nil
    }

    /// Adds a seat with `role`, named and placed as Add Seat would suggest, on the role's own runtime.
    func addSeat(with role: Role) {
        guard let draft else { return }
        let (member, pod) = suggestion(for: role)
        let probe = RigDraft.Seat.added(pod: pod, member: member, role: role.folder, runtime: "claude-code")
        addSeat(
            role: role, member: member, pod: pod, runtime: draft.roleDefault(probe).runtime, model: nil, effort: nil)
    }

    func pick(_ template: Template) {
        pickedID = template.id
        startsBlank = false
        use(template.draft)
    }

    func pickBlank() {
        pickedID = nil
        startsBlank = true
        use(RigDraft.blank())
    }

    private func use(_ template: RigDraft) {
        var draft = template
        draft.name = name
        #if DEBUG
            // OPENRIG_DEBUG_NEWRIG_RUNTIME=stub puts every agent seat on that runtime, since a pop-up menu can't be
            // chosen from in a background copy.
            if let runtime = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_NEWRIG_RUNTIME"] {
                for i in draft.seats.indices where !draft.seats[i].isTerminal { draft.seats[i].runtime = runtime }
            }
        #endif
        draft.cwd = folder?.path
        self.draft = draft
        roles = Dictionary(uniqueKeysWithValues: draft.seats.map { ($0.id, draft.roleName($0)) })
        roleDefaults = draft.seats.reduce(into: [:]) { $0[$1.id] = draft.roleDefault($1) }
    }

    /// What's missing before Continue, said under the button. Nil when Start is complete.
    var startProblem: String? {
        if folder == nil { return "Choose the project folder." }
        if let problem = RigName.problem(name) { return problem }
        if existingRigs.contains(name) { return "A rig named \(name) already exists." }
        if picked == nil, !startsBlank { return "Pick a template or a blank rig." }
        return nil
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

    func remove(_ id: RigDraft.Seat.ID) {
        draft?.remove(id)
        if detailSeat == id { detailSeat = nil }
    }

    // MARK: Seat detail

    /// The seat whose detail is open on the Seats step.
    var detailSeat: RigDraft.Seat.ID?

    func seat(_ id: RigDraft.Seat.ID) -> RigDraft.Seat? { draft?.seats.first { $0.id == id } }

    /// OpenRig's `daemon/assets`, found beside a built-in template.
    var assets: URL? { templates.lazy.compactMap { RigDraft.assets(besideShippedSpec: $0.path.path) }.first }

    func guidance(for seat: RigDraft.Seat) -> [GuidanceLayer] {
        draft?.guidance(for: seat, project: folder, assets: assets) ?? []
    }

    func roleSkills(for seat: RigDraft.Seat) -> [String] { draft?.roleSkills(seat) ?? [] }

    /// What + Add Skill offers: skills OpenRig can install, less the role's and the ones already added.
    func skillChoices(for seat: RigDraft.Seat) -> [SkillChoice] {
        let added = Set(seat.addedSkills.map(\.id))
        return (draft?.skillChoices(for: seat, project: folder, catalog: openRigHome.appending(path: "skills")) ?? [])
            .filter { !added.contains($0.id) }
    }

    func setNotes(_ notes: String, for id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }) else { return }
        draft?.seats[i].notes = notes
    }

    func addSkill(_ skill: SkillChoice, to id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }),
            draft?.seats[i].addedSkills.contains(where: { $0.id == skill.id }) == false
        else { return }
        draft?.seats[i].addedSkills.append(skill)
    }

    func removeSkill(_ skillID: SkillChoice.ID, from id: RigDraft.Seat.ID) {
        guard let i = draft?.seats.firstIndex(where: { $0.id == id }) else { return }
        draft?.seats[i].addedSkills.removeAll { $0.id == skillID }
    }

    /// A member id and pod for a new seat of `role`.
    func suggestion(for role: Role) -> (member: String, pod: String) {
        edgeRules.suggestion(for: role, taken: draft?.takenMembers ?? [])
    }

    /// What's wrong with a new seat's name or pod, or nil.
    func addSeatProblem(member: String, pod: String) -> String? {
        SeatName.problem(member, taken: draft?.takenMembers ?? []) ?? SeatName.podProblem(pod)
    }

    /// Adds a seat with the edges its role has in the templates.
    func addSeat(
        role: Role, member: String, pod: String, runtime: String, model: String?, effort: String?
    ) {
        guard var draft else { return }
        var seat = RigDraft.Seat.added(pod: pod, member: member, role: role.folder, runtime: runtime)
        seat.model = model
        seat.effort = effort
        draft.add(seat, edges: edgeRules.edges(for: seat, in: draft))
        self.draft = draft
        roles[seat.id] = role.name
        roleDefaults[seat.id] = draft.roleDefault(seat)
    }

    var seatsProblem: String? { draft?.seats.isEmpty == false ? nil : "A rig needs at least one seat." }

    // MARK: Review

    /// Writes the spec and runs preflight on it: what Launch runs is what was checked. Before the first save that is
    /// a staged folder; after one, the saved folder itself (`SpecLaunch`).
    func review() async {
        guard let draft else { return }
        let template = picked
        preflight = nil
        do {
            yaml = try draft.yaml()
            if let savedSpec {
                try yaml.write(to: savedSpec.appending(path: "rig.yaml"), atomically: true, encoding: .utf8)
            } else {
                staged = try stage(yaml, from: template)
            }
            // Seat notes and added skills: member startup files beside rig.yaml.
            if let spec = savedSpec ?? staged { try draft.writeSeatFiles(into: spec) }
        } catch {
            preflight = Preflight(errors: ["Couldn't write the spec: \(error.localizedDescription)"])
            return
        }
        var result = Preflight()
        if savedSpec == nil, FileManager.default.fileExists(atPath: destination.path) {
            result.errors.append("\(destination.path) already exists. Pick another rig name, or remove that spec.")
        }
        guard let cli = actions.cli, let plan = launchPlan else {
            result.errors.append("rig not found. Pick it in Settings › Connection.")
            preflight = result
            return
        }
        // `rig up --plan` runs the launch's own preflight. The spec carries the project folder as each seat's cwd,
        // so no --cwd: what is checked is what a later `rig up <name>` gets.
        let args = ["up", plan.checked + "/rig.yaml", "--plan", "--json"]
        if let out = try? await cli.run(arguments: args),
            let report = try? JSONDecoder().decode(PreflightReport.self, from: Data(out.stdout.utf8))
        {
            result.errors += report.errors
            result.warnings += report.warnings
        } else {
            result.errors.append("rig up --plan didn't answer.")
        }
        preflight = result
    }

    private var launchPlan: SpecLaunch? {
        guard let staged = staged ?? savedSpec else { return nil }
        return SpecLaunch(staged: staged.path, saved: savedSpec?.path, library: destination.path)
    }

    /// After a save, the spec's name and folder are fixed: Start can't change the name or the template.
    var isSaved: Bool { savedSpec != nil }

    /// Removes the staged folder, for Cancel or once the rig is launched.
    func discardStaging() {
        if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        staged = nil
    }

    /// Preflight's messages, one row per thing, naming the seats each is about.
    func notes(_ messages: [String]) -> [PreflightNote] {
        PreflightNote.group(messages, seats: draft?.seats.map(\.id) ?? [])
    }

    private struct PreflightReport: Decodable {
        var errors: [String]
        var warnings: [String]
    }

    /// A fresh folder named after the rig, holding the template folder's files (its culture and guidance, which
    /// relative paths name) and the new rig.yaml. A template that is a lone file at the top of the person's library
    /// gets only its rig.yaml: its folder is the whole library.
    private func stage(_ yaml: String, from template: Template?) throws -> URL {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appending(path: "OpenRig-NewRig-\(UUID().uuidString)")
        let folder = parent.appending(path: name)
        let source = template?.path.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if let source, source.standardizedFileURL != specsRoot.standardizedFileURL {
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

    /// The commands Launch runs, with full paths: a quoted "~" wouldn't expand if pasted into a shell.
    var commands: [String] {
        let plan = launchPlan ?? SpecLaunch(staged: destination.path, library: destination.path)
        return plan.steps().map(\.userCommand)
    }

    var isLaunching: Bool { actions.isRunning(Self.actionKey) }

    /// `rig specs add` (first time only), then `rig up` on the saved spec. True once the rig is starting.
    func launch() async -> Bool {
        guard folder != nil, preflight?.ready == true, var plan = launchPlan else { return false }
        if plan.saved == nil {
            guard
                let added = await actions.result(
                    of: .addSpec(folder: plan.staged), key: Self.actionKey, success: "Saved \(name) to your library")
            else { return false }
            struct Added: Decodable { var path: String? }
            let path = (try? JSONDecoder().decode(Added.self, from: Data(added.stdout.utf8)))?.path
            savedSpec = path.map { URL(filePath: $0) } ?? destination
            discardStaging()
            plan.saved = savedSpec?.path
        }
        for step in plan.steps() {
            guard await actions.perform(step, key: Self.actionKey, success: "Starting \(name)'s seats") else {
                return false
            }
        }
        await launched(name)
        return true
    }
}
extension NewRigStore: Identifiable {}

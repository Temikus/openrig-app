import Foundation
import Observation
import RigClient
import RigDomain

/// New role: one line from the person, a draft from the kernel's lead, then a saved role and a seat with it.
///
/// The ask is a queue row to the kernel's lead (work, so it survives a restart), naming a folder this store owns and
/// the files to write there (`RoleDraft.ask`). The store watches that folder for `READY` and checks the row's state
/// every few seconds, so a refusal shows too. It never reads the lead's screen.
@MainActor @Observable
final class NewRoleStore {
    enum Phase: Equatable {
        case idle
        case drafting
        case drafted
        case failed(String)
        case saving
    }

    /// The kernel's lead: it pilots the person's intent and designs topology (`openrig-architect`).
    static let drafter = "advisor-lead@kernel"
    static let actionKey = "newrole"
    /// How long a draft may take before the sheet says it didn't come.
    static let patience: Duration = .seconds(600)

    var line = ""
    var draft: RoleDraft?
    private(set) var phase = Phase.idle
    private(set) var rowID: String?
    /// The skills a role can name, found once.
    private(set) var available: [SkillChoice] = []
    /// OpenRig's checks on a saved role, when they fail.
    private(set) var saveError: String?

    private let rig: NewRigStore
    private let actions: ActionStore
    private var folder: URL?
    private var waiting: Task<Void, Never>?

    init(rig: NewRigStore, actions: ActionStore) {
        self.rig = rig
        self.actions = actions
        if let shared = rig.sharedRoleFolder {
            available = RoleDraft.availableSkills(shared: shared, project: rig.folder, catalog: rig.skillCatalog)
        }
        actions.clear(Self.actionKey)
    }

    var unknownSkills: Set<String> { Set(draft?.unknownSkills(available: available) ?? []) }

    var problems: [String] {
        guard let draft else { return [] }
        return draft.problems(roles: Set(rig.roleLibrary.map(\.name)), taken: rig.specFolderNames)
    }

    /// Where the role will be saved, for the sheet to say.
    var savedPath: String? {
        draft.map { rig.specsRoot.appending(path: $0.name).path(percentEncoded: false) }
    }

    // MARK: Drafting

    func draftRole() {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, phase != .drafting else { return }
        stopWaiting()
        phase = .drafting
        saveError = nil
        waiting = Task { await self.run(line) }
    }

    func cancel() {
        let row = rowID
        stopWaiting()
        if phase == .drafting { phase = draft == nil ? .idle : .drafted }
        if let row {
            Task {
                await actions.perform(
                    .close(id: row, reason: .canceled, target: nil, resolution: "The person cancelled the draft."),
                    key: Self.actionKey, success: "Cancelled the draft")
            }
        }
    }

    /// Removes the drafting folder, for when the sheet closes.
    func discard() {
        stopWaiting()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    private func stopWaiting() {
        waiting?.cancel()
        waiting = nil
        rowID = nil
    }

    private func run(_ line: String) async {
        let fm = FileManager.default
        if let folder { try? fm.removeItem(at: folder) }
        let folder = fm.temporaryDirectory.appending(path: "OpenRig-NewRole-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't make a folder for the draft: \(error.localizedDescription)")
            return
        }
        self.folder = folder
        let (wakes, wake) = AsyncStream<Void>.makeStream()
        let watcher = Self.watch(folder, wake: wake)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                wake.yield()
            }
        }
        defer {
            watcher?.cancel()
            ticker.cancel()
            wake.finish()
        }
        if let canned = Self.cannedDraft {
            // DEBUG: a prepared folder stands in for the kernel's lead, so a test costs no tokens.
            Task {
                try? await Task.sleep(for: .seconds(1))
                for name in (try? fm.contentsOfDirectory(atPath: canned.path)) ?? [] {
                    try? fm.copyItem(at: canned.appending(path: name), to: folder.appending(path: name))
                }
            }
        } else {
            guard rig.kernelExists else {
                phase = .failed("There is no kernel rig, so no one can draft the role.")
                return
            }
            let body = RoleDraft.ask(
                line: line, project: (rig.folder ?? folder).path(percentEncoded: false),
                folder: folder.path(percentEncoded: false), skills: available)
            guard
                let created = await actions.result(
                    of: .create(
                        destination: Self.drafter, summary: "Draft a role for New Rig: \(line.prefix(80))", body: body,
                        priority: .routine),
                    key: Self.actionKey, success: "Asked the kernel's lead for a draft")
            else {
                phase = .failed("Couldn't ask the kernel's lead. The command's error is below.")
                return
            }
            rowID = created.stdout.firstMatch(of: /qitem-[0-9A-Za-z-]+/).map { String($0.output) }
        }
        let deadline = ContinuousClock.now + Self.patience
        for await _ in wakes {
            if Task.isCancelled { return }
            if fm.fileExists(atPath: folder.appending(path: RoleDraft.Files.ready).path) {
                do {
                    draft = try RoleDraft.read(from: folder)
                    phase = .drafted
                } catch {
                    phase = .failed(error.message)
                }
                rowID = nil
                return
            }
            if let closed = await closedWithout() {
                phase = .failed(closed)
                rowID = nil
                return
            }
            if ContinuousClock.now > deadline {
                phase = .failed(
                    "No draft came back in \(Int(Self.patience.components.seconds / 60)) minutes. The ask is still in "
                        + "the kernel's lead's queue; Cancel withdraws it.")
                return
            }
        }
    }

    /// The row's closure, when the lead closed it without writing READY.
    private func closedWithout() async -> String? {
        guard let rowID, let cli = actions.cli,
            let out = try? await cli.run(arguments: ["queue", "show", rowID, "--json"])
        else { return nil }
        struct Row: Decodable {
            var state: String
            var resolution: String?
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(out.stdout.utf8)), row.state == "done" else {
            return nil
        }
        return "The kernel's lead closed the ask without a draft"
            + (row.resolution.map { ": \($0)" } ?? ".")
    }

    /// Wakes on every change in `folder` (a file written, renamed or removed).
    private nonisolated static func watch(_ folder: URL, wake: AsyncStream<Void>.Continuation)
        -> DispatchSourceFileSystemObject?
    {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { wake.yield() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private static var cannedDraft: URL? {
        #if DEBUG
            ProcessInfo.processInfo.environment["OPENRIG_DEBUG_NEWROLE_DRAFT"].map { URL(filePath: $0) }
        #else
            nil
        #endif
    }

    // MARK: Saving

    /// Checks the role with OpenRig (`rig agent validate`), saves it to the person's library (`rig specs add`), and
    /// adds a seat with it to the rig being built. True once the seat is added.
    func save() async -> Bool {
        guard let draft, problems.isEmpty, let shared = rig.sharedRoleFolder, let cli = actions.cli else {
            return false
        }
        phase = .saving
        saveError = nil
        defer { if phase == .saving { phase = .drafted } }
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appending(path: "OpenRig-NewRole-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: parent) }
        let staged = parent.appending(path: draft.name)
        do {
            try draft.write(into: staged, shared: shared, available: available)
        } catch {
            saveError = "Couldn't write the role: \(error.localizedDescription)"
            return false
        }
        let spec = staged.appending(path: RoleDraft.Files.agent).path(percentEncoded: false)
        if let out = try? await cli.run(arguments: ["agent", "validate", spec, "--json"]) {
            struct Check: Decodable {
                var valid: Bool
                var errors: [String]
            }
            if let check = try? JSONDecoder().decode(Check.self, from: Data(out.stdout.utf8)), !check.valid {
                saveError = "OpenRig refused the role: " + check.errors.joined(separator: "; ")
                return false
            }
        }
        guard
            let added = await actions.result(
                of: .addSpec(folder: staged.path(percentEncoded: false)), key: Self.actionKey,
                success: "Saved the \(draft.name) role to your library")
        else {
            saveError = "rig specs add didn't save the role. The command's error is below."
            return false
        }
        struct Added: Decodable { var path: String? }
        let path = (try? JSONDecoder().decode(Added.self, from: Data(added.stdout.utf8)))?.path
        let saved = URL(filePath: path ?? rig.specsRoot.appending(path: draft.name).path)
        guard let role = await rig.addedRole(at: saved) else {
            saveError = "The role was saved to \(saved.path), but the library doesn't list it yet."
            return false
        }
        rig.addSeat(with: role)
        discard()
        return true
    }
}

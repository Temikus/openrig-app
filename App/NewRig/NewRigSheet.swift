import RigDomain
import RigModel
import SwiftUI

/// Rig › New Rig…: three steps in a sheet over the main window (Start, Seats, Review), then Launch Rig.
struct NewRigSheet: View {
    @State var model: NewRigStore
    @Environment(ActionStore.self) private var actions
    @Environment(\.dismiss) private var dismiss

    /// The parent window's content size: the sheet never grows past it, so the footer stays on screen.
    @State private var room: CGSize?

    var body: some View {
        HStack(spacing: 0) {
            steps
            Divider()
            ScrollView {
                Group {
                    switch model.step {
                    case .start: NewRigStart(model: model)
                    case .seats: NewRigSeats(model: model)
                    case .review: NewRigReview(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(width: Self.side(960, room?.width, floor: 600), height: Self.side(640, room?.height, floor: 380))
        .background(ParentWindowSize(size: $room))
        .task { await model.load() }
        .onDisappear { model.discardStaging() }
    }

    /// `ideal`, shrunk to fit `room` with a margin, but not below `floor`.
    static func side(_ ideal: CGFloat, _ room: CGFloat?, floor: CGFloat) -> CGFloat {
        guard let room else { return ideal }
        return max(floor, min(ideal, room - 40))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(NewRigStore.Step.allCases) { step in
                Text("\(step.rawValue + 1)  \(step.title)")
                    .font(.body.weight(step == model.step ? .semibold : .regular))
                    .foregroundStyle(step == model.step ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(step == model.step ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                    .accessibilityAddTraits(step == model.step ? .isSelected : [])
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 130)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }

    private var problem: String? {
        switch model.step {
        case .start: model.startProblem
        case .seats: model.seatsProblem
        case .review:
            model.preflight.map { preflight in
                let count = model.notes(preflight.errors).count
                return preflight.ready ? nil : "\(count) thing\(count == 1 ? "" : "s") to fix before launch"
            } ?? nil
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .failed(let message)? = actions.status[NewRigStore.actionKey] {
                Text(message).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            } else if model.isLaunching {
                ProgressView().controlSize(.small)
                Text("Launching \(model.name)…").foregroundStyle(.secondary)
            } else if let problem {
                Text(problem).foregroundStyle(model.step == .review ? .red : .secondary)
            } else if model.step == .start, let picked = model.picked {
                Text("\(picked.entry.name) · \(seatCount(picked.draft.seats.count)) · you can change any seat next")
                    .foregroundStyle(.secondary)
            } else if model.step == .start, model.startsBlank {
                Text("Blank rig · add its seats next").foregroundStyle(.secondary)
            } else if model.step == .seats, let draft = model.draft {
                Text(seatCount(draft.seats.count)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.step != .start {
                Button("Back") { model.step = NewRigStore.Step(rawValue: model.step.rawValue - 1) ?? .start }
                    .disabled(model.isLaunching)
            }
            if model.step == .review {
                Button("Launch Rig") {
                    Task { if await model.launch() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.preflight?.ready != true || model.isLaunching)
            } else {
                Button("Continue") {
                    model.step = NewRigStore.Step(rawValue: model.step.rawValue + 1) ?? .review
                    if model.step == .review { Task { await model.review() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

func seatCount(_ n: Int) -> String { n == 1 ? "1 seat" : "\(n) seats" }

// MARK: - Start

struct NewRigStart: View {
    @Bindable var model: NewRigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What will this rig work on?").font(.title2.bold())
                Text(
                    "Pick the project folder, then start from a template or a blank rig. You can change every seat on "
                        + "the next step."
                )
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project folder").font(.caption).foregroundStyle(.secondary)
                    Text(model.folder?.path(percentEncoded: false) ?? "None")
                        .font(.callout.monospaced())
                        .foregroundStyle(model.folder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                        .accessibilityLabel("Project folder")
                        .accessibilityValue(model.folder?.path(percentEncoded: false) ?? "None")
                }
                Button("Choose…") { model.chooseFolder() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rig name").font(.caption).foregroundStyle(.secondary)
                    TextField(
                        "Rig name",
                        text: Binding(
                            get: { model.name },
                            set: {
                                model.name = $0; model.nameEdited = true
                            })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Rig name")
                    .disabled(model.isSaved)
                }
                .frame(width: 220)
            }
            if model.isSaved {
                Text(
                    "\(model.name) is saved to your library, so its name and template are fixed. Seats can still change."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker(
                    "Start from",
                    selection: Binding(
                        get: { model.startsBlank },
                        set: { blank in
                            if blank {
                                model.pickBlank()
                            } else if let first = model.templates.first {
                                model.pick(first)
                            }
                        })
                ) {
                    Text("Template").tag(false)
                    Text("Blank rig").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isSaved)
                Text(
                    model.startsBlank
                        ? "No seats yet: add each one, with its role, on the next step."
                        : "Templates are the rig specs OpenRig ships, plus ones you saved."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.startsBlank {
                EmptyView()
            } else if model.loading {
                ProgressView("Reading the spec library…").frame(maxWidth: .infinity)
            } else if let error = model.loadError {
                Text(error).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(model.templates) { template in
                        TemplateCard(template: template, picked: template.id == model.pickedID) {
                            model.pick(template)
                        }
                        .disabled(model.isSaved && template.id != model.pickedID)
                    }
                }
            }
        }
    }
}

struct TemplateCard: View {
    let template: NewRigStore.Template
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(template.entry.name).font(.headline)
                    Spacer()
                    Text(seatCount(template.draft.seats.count)).font(.caption).foregroundStyle(.secondary)
                }
                Text(template.entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(template.draft.seats.map(\.member).joined(separator: " · "))
                    .font(.caption2)
                    .lineLimit(2)
                Text(template.entry.isBuiltin ? "Ships with OpenRig" : "Your saved spec")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(.quaternary.opacity(picked ? 0.8 : 0.35), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.entry.name), \(seatCount(template.draft.seats.count))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: - Seats

struct NewRigSeats: View {
    @Bindable var model: NewRigStore
    @State private var addingSeat = false

    @Environment(ActionStore.self) private var actions

    var body: some View {
        Group {
            if let id = model.detailSeat, let seat = model.seat(id) {
                SeatDetail(model: model, seat: seat)
            } else {
                list
            }
        }
        .sheet(isPresented: $model.makingRole) { NewRoleSheet(rig: model, actions: actions) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Seats").font(.title2.bold())
                    Spacer()
                    Button("Add Seat…", systemImage: "plus") { addingSeat = true }
                        .disabled(model.roleLibrary.isEmpty)
                        .help(model.roleLibrary.isEmpty ? "No roles in the library" : "Add a seat with a role")
                }
                Text(
                    model.startsBlank
                        ? "A blank rig. Add the seats it needs; each one's edges come from its role."
                        : "From \(model.picked?.entry.name ?? "the template"). Change a runtime, model or effort, "
                            + "or add and remove seats."
                )
                .foregroundStyle(.secondary)
            }
            if let draft = model.draft {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Seat")
                            Text("Role")
                            Text("Runtime")
                            Text("Model")
                            Text("Effort")
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(draft.seats) { seat in
                            SeatRow(model: model, seat: seat)
                        }
                    }
                }
            }
            Text(
                "Each runtime lists its own models: Claude Code's from claude --help, Codex's from its catalogue. "
                    + "\u{201C}Role default\u{201D} leaves the model out, so the runtime or the role decides."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let draft = model.draft, !draft.addedEdges.isEmpty {
                Text(edgesNote(draft))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $addingSeat) { AddSeatSheet(model: model) }
    }

    /// The added seats' edges, said plainly: the Review spec shows them in full.
    private func edgesNote(_ draft: RigDraft) -> String {
        let lines = draft.addedEdges.map { "\($0.from) \($0.kind.replacingOccurrences(of: "_", with: " ")) \($0.to)" }
        return "Edges come from the roles: " + lines.joined(separator: ", ") + "."
    }
}

/// Add a seat: a role from the library, then its name, pod, runtime, model and effort.
struct AddSeatSheet: View {
    let model: NewRigStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var role: Role?
    @State private var member = ""
    @State private var pod = ""
    @State private var newPod = false
    @State private var runtime = "claude-code"
    @State private var modelID: String?
    @State private var effort: String?
    @State private var typedModel = ""

    private static let other = "\u{0}other"

    private var shown: [Role] {
        search.isEmpty
            ? model.roleLibrary
            : model.roleLibrary.filter {
                $0.name.localizedStandardContains(search) || $0.summary.localizedStandardContains(search)
            }
    }

    private var problem: String? {
        guard role != nil else { return "Pick a role." }
        if modelID == Self.other, ModelChoices.typed(typedModel) == nil { return "Type a model ID." }
        return model.addSeatProblem(member: member, pod: pod)
    }

    var body: some View {
        let choices = model.choices(for: runtime)
        let agentSeat = runtime != Runtime.terminal && runtime != "stub"
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add a seat").font(.headline)
                Spacer()
                TextField("Search roles", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("Search roles")
            }
            List(
                shown,
                selection: Binding(get: { role?.id }, set: { id in pick(model.roleLibrary.first { $0.id == id }) })
            ) { role in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(role.name).fontWeight(.semibold).frame(width: 150, alignment: .leading)
                    Text(role.summary).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(role.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(role.name)
            }
            .frame(minHeight: 160, maxHeight: 280)
            .accessibilityLabel("Roles")
            Button("None of the roles fit? Make a new role…") {
                dismiss()
                model.makingRole = true
            }
            .buttonStyle(.link)
            .disabled(model.sharedRoleFolder == nil)
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                field("Seat name") {
                    TextField("Seat name", text: $member).frame(width: 120).accessibilityLabel("Seat name")
                }
                field("Pod") {
                    if newPod {
                        TextField("Pod", text: $pod).frame(width: 110).accessibilityLabel("Pod")
                    } else {
                        Picker("Pod", selection: Binding(get: { pod }, set: { choosePod($0) })) {
                            ForEach(pods, id: \.self) { Text($0).tag($0) }
                            Divider()
                            Text("New pod…").tag(Self.other)
                        }
                        .labelsHidden().frame(width: 110)
                    }
                }
                field("Runtime") {
                    Picker("Runtime", selection: Binding(get: { runtime }, set: { setRuntime($0) })) {
                        ForEach(Runtime.all, id: \.self) { Text(Runtime.label($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                }
                field("Model") {
                    Picker("Model", selection: $modelID) {
                        Text(ModelChoices.roleDefault(model: roleDefault?.model(on: runtime), runtime: runtime))
                            .tag(String?.none)
                        ForEach(choices.models) { Text($0.label).tag(Optional($0.id)) }
                        Divider()
                        Text("Other…").tag(Optional(Self.other))
                    }
                    .labelsHidden().frame(width: 150).disabled(!agentSeat)
                }
                field("Effort") {
                    Picker("Effort", selection: $effort) {
                        Text("Default").tag(String?.none)
                        ForEach(choices.efforts(for: modelID), id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(width: 90).disabled(!agentSeat)
                }
            }
            if modelID == Self.other {
                TextField("Model ID, such as claude-opus-5-5", text: $typedModel)
                    .frame(width: 260)
                    .accessibilityLabel("Model ID")
            }
            HStack {
                Text(problem ?? " ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Seat", action: add).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 640)
    }

    private var pods: [String] {
        var pods = model.draft?.pods ?? []
        if !pod.isEmpty, !pods.contains(pod) { pods.append(pod) }
        return pods
    }

    private var roleDefault: RoleDefault? {
        guard let role, let draft = model.draft else { return nil }
        return draft.roleDefault(RigDraft.Seat.added(pod: pod, member: member, role: role.folder, runtime: runtime))
    }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// A role fills in the seat's usual name and pod, and its own runtime.
    private func pick(_ picked: Role?) {
        role = picked
        guard let picked else { return }
        let suggestion = model.suggestion(for: picked)
        member = suggestion.member
        pod = suggestion.pod
        newPod = false
        if let draft = model.draft {
            let seat = RigDraft.Seat.added(pod: pod, member: member, role: picked.folder, runtime: runtime)
            setRuntime(draft.roleDefault(seat).runtime)
        }
    }

    private func choosePod(_ choice: String) {
        if choice == Self.other {
            newPod = true
            pod = ""
        } else {
            pod = choice
        }
    }

    private func setRuntime(_ new: String) {
        runtime = new
        let listed = model.choices(for: new)
        if let id = modelID, id != Self.other, !listed.models.contains(where: { $0.id == id }) { modelID = nil }
        if let level = effort, !listed.efforts(for: modelID).contains(level) { effort = nil }
    }

    private func add() {
        guard let role, problem == nil else { return }
        let chosen = modelID == Self.other ? ModelChoices.typed(typedModel) : modelID
        let agentSeat = runtime != Runtime.terminal && runtime != "stub"
        model.addSeat(
            role: role, member: member, pod: pod, runtime: runtime, model: agentSeat ? chosen : nil,
            effort: agentSeat ? effort : nil)
        dismiss()
    }
}

struct SeatRow: View {
    let model: NewRigStore
    let seat: RigDraft.Seat
    /// "Other…": a full model ID, for a version or line the runtime's list doesn't name.
    @State private var typing = false
    @State private var typed = ""
    private static let other = "\u{0}other"

    var body: some View {
        let choices = model.choices(for: seat.runtime)
        let agentSeat = seat.runtime != Runtime.terminal && seat.runtime != "stub"
        GridRow {
            VStack(alignment: .leading, spacing: 0) {
                if seat.runtime == Runtime.terminal {
                    Text(seat.member).fontWeight(.semibold)
                } else {
                    // Opens the seat's detail: its guidance, notes and skills.
                    Button(seat.member) { model.detailSeat = seat.id }
                        .buttonStyle(.link)
                        .fontWeight(.semibold)
                        .help("Show what \(seat.member) reads at startup, and its skills")
                        .accessibilityLabel("Seat detail for \(seat.id)")
                }
                Text(seat.pod).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.roles[seat.id] ?? "").lineLimit(1)
            Picker(
                "Runtime for \(seat.id)",
                selection: Binding(get: { seat.runtime }, set: { model.setRuntime($0, for: seat.id) })
            ) {
                ForEach(seat.isTerminal ? [Runtime.terminal] : Runtime.all, id: \.self) {
                    Text(Runtime.label($0)).tag($0)
                }
            }
            .labelsHidden()
            .disabled(seat.isTerminal)
            Picker(
                "Model for \(seat.id)",
                selection: Binding(
                    get: { seat.model },
                    set: {
                        if $0 == Self.other {
                            typed = seat.model ?? ""
                            typing = true
                        } else {
                            model.setModel($0, for: seat.id)
                        }
                    })
            ) {
                let role = model.roleDefaults[seat.id]?.model(on: seat.runtime)
                Text(ModelChoices.roleDefault(model: role, runtime: seat.runtime)).tag(String?.none)
                ForEach(choices.models(including: seat.model)) { Text($0.label).tag(Optional($0.id)) }
                Divider()
                Text("Other…").tag(Optional(Self.other))
            }
            .labelsHidden()
            .disabled(!agentSeat)
            .popover(isPresented: $typing, arrowEdge: .bottom) { otherModel }
            Picker(
                "Effort for \(seat.id)",
                selection: Binding(get: { seat.effort }, set: { model.setEffort($0, for: seat.id) })
            ) {
                Text("Default").tag(String?.none)
                ForEach(levels(choices), id: \.self) { Text($0.capitalized).tag(Optional($0)) }
            }
            .labelsHidden()
            .disabled(!agentSeat)
            Button {
                model.remove(seat.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove \(seat.id) and its edges")
            .accessibilityLabel("Remove \(seat.id)")
        }
    }

    private var otherModel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model ID for \(seat.member)").font(.headline)
            TextField("claude-opus-5-5", text: $typed)
                .frame(width: 240)
                .onSubmit(useTyped)
                .accessibilityLabel("Model ID for \(seat.id)")
            Text("Written to the spec as typed. It isn't checked until the seat starts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { typing = false }
                Button("Use", action: useTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ModelChoices.typed(typed) == nil)
            }
        }
        .frame(width: 260)
        .padding()
    }

    private func useTyped() {
        guard let id = ModelChoices.typed(typed) else { return }
        model.setModel(id, for: seat.id)
        typing = false
    }

    private func levels(_ choices: ModelChoices) -> [String] {
        var levels = choices.efforts(for: seat.model)
        if let effort = seat.effort, !levels.contains(effort) { levels.append(effort) }
        return levels
    }
}

// MARK: - Review

struct NewRigReview: View {
    let model: NewRigStore
    @State private var showsWarnings = false

    /// The width Review has. The layout follows it, not the text's own width: a staged path is one long word, and
    /// ViewThatFits measured it unwrapped, so the spec never went beside the checks.
    @State private var width: CGFloat = 0
    static let sideBySide: CGFloat = 340 + 24 + 320

    var body: some View {
        Group {
            if width >= Self.sideBySide {
                HStack(alignment: .top, spacing: 24) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    spec(height: 420).frame(width: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    summary
                    spec(height: 260)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width.rounded()
        } action: {
            width = $0
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to launch \(model.name)?").font(.title2.bold())
                Text(
                    "\(seatCount(model.draft?.seats.count ?? 0)) in \(model.folder?.path(percentEncoded: false) ?? ""). "
                        + "Each seat starts in its own terminal."
                )
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(model.folder?.path(percentEncoded: false) ?? "")
            }
            checks
            VStack(alignment: .leading, spacing: 6) {
                Text("Runs").font(.caption).foregroundStyle(.secondary)
                Text(model.commands.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                Text(
                    model.isSaved
                        ? "The spec is already in your library; Launch starts the rig from it, with these edits."
                        : "The first saves the spec to your library; the second starts the rig from it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func spec(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("rig.yaml").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.yaml, forType: .string)
                    announce("Copied rig.yaml")
                }
                .controlSize(.small)
                .disabled(model.yaml.isEmpty)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(model.yaml)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: height)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .accessibilityLabel("rig.yaml")
        }
    }

    /// Errors stay open, above the warnings; warnings fold behind their count.
    @ViewBuilder private var checks: some View {
        if let preflight = model.preflight {
            let errors = model.notes(preflight.errors)
            let warnings = model.notes(preflight.warnings)
            VStack(alignment: .leading, spacing: 8) {
                if errors.isEmpty { CheckLine(text: "Preflight passed", tone: .ok) }
                ForEach(errors) { CheckLine(note: $0, tone: .error) }
                if !warnings.isEmpty {
                    DisclosureGroup(isExpanded: $showsWarnings) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(warnings) { CheckLine(note: $0, tone: .warning) }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label(
                            warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                    }
                }
            }
            Text(
                "Checks come from rig up --plan on the spec as it will be saved, before anything starts."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView("Checking the spec…").controlSize(.small)
        }
    }
}

struct CheckLine: View {
    enum Tone { case ok, warning, error }
    let text: String
    var seats: [String] = []
    /// OpenRig's own words, when the line rewords them.
    var detail: [String] = []
    let tone: Tone

    init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    init(note: PreflightNote, tone: Tone) {
        text = note.text
        seats = note.seats
        detail = note.detail.filter { $0 != note.text }
        self.tone = tone
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(tone == .error ? .red : .primary)
                if !seats.isEmpty {
                    Text(seats.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .help(detail.joined(separator: "\n"))
        } icon: {
            switch tone {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

/// Reports the size of the window a sheet hangs from, and keeps reporting as that window resizes.
struct ParentWindowSize: NSViewRepresentable {
    @Binding var size: CGSize?

    func makeNSView(context: Context) -> Reader { Reader(size: $size) }
    func updateNSView(_ view: Reader, context: Context) {}

    final class Reader: NSView {
        let size: Binding<CGSize?>
        private var observer: NSObjectProtocol?

        init(size: Binding<CGSize?>) {
            self.size = size
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            attach(tries: 20)
        }

        /// The sheet window gets its parent only once it is presented, after this view joins it: look again shortly.
        private func attach(tries: Int) {
            guard let window else { return }
            guard let parent = window.sheetParent else {
                if tries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.attach(tries: tries - 1)
                    }
                }
                return
            }
            report(parent)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self, weak parent] _ in
                MainActor.assumeIsolated {
                    if let parent { self?.report(parent) }
                }
            }
        }

        private func report(_ parent: NSWindow) {
            let room = parent.contentLayoutRect.size
            if size.wrappedValue != room { size.wrappedValue = room }
        }
    }
}

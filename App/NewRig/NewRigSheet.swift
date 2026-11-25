import RigDomain
import RigModel
import SwiftUI

/// Rig › New Rig…: three steps in a sheet over the main window (Start, Seats, Review), then Launch Rig.
struct NewRigSheet: View {
    @State var model: NewRigStore
    @Environment(ActionStore.self) private var actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            steps
            Divider()
            Group {
                switch model.step {
                case .start: NewRigStart(model: model)
                case .seats: NewRigSeats(model: model)
                case .review: NewRigReview(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 560, idealHeight: 640)
        .task { await model.load() }
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
        .frame(width: 160)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }

    private var problem: String? {
        switch model.step {
        case .start: model.startProblem
        case .seats: model.seatsProblem
        case .review:
            model.preflight.map {
                $0.ready ? nil : "\($0.errors.count) thing\($0.errors.count == 1 ? "" : "s") to fix before launch"
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
            } else if model.step == .seats, let draft = model.draft {
                Text(seatCount(draft.seats.count)).foregroundStyle(.secondary)
            }
            Spacer()
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
                Text("Pick the project folder, then a template. You can change every seat on the next step.")
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
                }
                .frame(width: 220)
            }
            Text("Templates are the rig specs OpenRig ships, plus ones you saved.")
                .font(.caption).foregroundStyle(.secondary)
            if model.loading {
                ProgressView("Reading the spec library…").frame(maxWidth: .infinity)
            } else if let error = model.loadError {
                Text(error).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(model.templates) { template in
                            TemplateCard(template: template, picked: template.id == model.pickedID) {
                                model.pick(template)
                            }
                        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seats").font(.title2.bold())
                Text(
                    "From \(model.picked?.entry.name ?? "the template"). Change a runtime, model or effort, or remove a seat."
                )
                .foregroundStyle(.secondary)
            }
            if let draft = model.draft {
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
            Text(
                "Each runtime lists its own models: Claude Code's from claude --help, Codex's from its catalogue. "
                    + "\u{201C}Role default\u{201D} leaves the model out, so the runtime or the role decides."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

struct SeatRow: View {
    let model: NewRigStore
    let seat: RigDraft.Seat

    var body: some View {
        let choices = model.choices(for: seat.runtime)
        let agentSeat = seat.runtime != Runtime.terminal && seat.runtime != "stub"
        GridRow {
            VStack(alignment: .leading, spacing: 0) {
                Text(seat.member).fontWeight(.semibold)
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
                selection: Binding(get: { seat.model }, set: { model.setModel($0, for: seat.id) })
            ) {
                Text("Role default").tag(String?.none)
                ForEach(choices.models(including: seat.model)) { Text($0.label).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .disabled(!agentSeat)
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

    private func levels(_ choices: ModelChoices) -> [String] {
        var levels = choices.efforts(for: seat.model)
        if let effort = seat.effort, !levels.contains(effort) { levels.append(effort) }
        return levels
    }
}

// MARK: - Review

struct NewRigReview: View {
    let model: NewRigStore

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to launch \(model.name)?").font(.title2.bold())
                    Text(
                        "\(seatCount(model.draft?.seats.count ?? 0)) in \(model.folder?.path(percentEncoded: false) ?? ""). Each seat starts in its own terminal."
                    )
                    .foregroundStyle(.secondary)
                }
                checks
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runs").font(.caption).foregroundStyle(.secondary)
                    Text(model.addCommand + "\n" + model.upCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    Text("The first saves the spec to your library; the second starts the rig from it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
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
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityLabel("rig.yaml")
            }
            .frame(width: 340)
        }
    }

    @ViewBuilder private var checks: some View {
        if let preflight = model.preflight {
            VStack(alignment: .leading, spacing: 8) {
                if preflight.errors.isEmpty && preflight.warnings.isEmpty {
                    CheckLine(text: "Preflight found nothing to fix", tone: .ok)
                } else if preflight.errors.isEmpty {
                    CheckLine(text: "Preflight passed", tone: .ok)
                }
                ForEach(preflight.errors, id: \.self) { CheckLine(text: $0, tone: .error) }
                ForEach(preflight.warnings, id: \.self) { CheckLine(text: $0, tone: .warning) }
            }
            Text("Checks come from rig spec preflight on the spec as it will be saved, before anything starts.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView("Checking the spec…").controlSize(.small)
        }
    }
}

struct CheckLine: View {
    enum Tone { case ok, warning, error }
    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text).foregroundStyle(tone == .error ? .red : .primary).fixedSize(horizontal: false, vertical: true)
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

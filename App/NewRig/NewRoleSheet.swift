import RigDomain
import SwiftUI

/// New role: the person's line, the kernel lead's draft, every field editable, then Save Role and Add Seat.
struct NewRoleSheet: View {
    @State private var role: NewRoleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionStore.self) private var actions

    init(rig: NewRigStore, actions: ActionStore) {
        _role = State(initialValue: NewRoleStore(rig: rig, actions: actions))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ask
                    if role.draft != nil { DraftEditor(role: role) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 820, height: 600)
        .onDisappear { role.discard() }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What should this seat do?").font(.headline)
            HStack(spacing: 8) {
                TextField("Reviews database migrations for safety before they merge", text: $role.line)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("What should this seat do?")
                    .onSubmit { role.draftRole() }
                    .disabled(role.phase == .drafting)
                Button(role.draft == nil ? "Draft Role" : "Draft Again") { role.draftRole() }
                    .disabled(role.line.trimmingCharacters(in: .whitespaces).isEmpty || role.phase == .drafting)
            }
            switch role.phase {
            case .drafting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting… the kernel's lead is writing the role.").foregroundStyle(.secondary)
                    Button("Cancel Draft") { role.cancel() }
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            default:
                Text(
                    "The kernel's lead drafts the role from this line and the project folder. You edit everything "
                        + "before it's saved."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .failed(let message)? = actions.status[NewRoleStore.actionKey] {
                Text(message).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            } else if let error = role.saveError {
                Text(error).foregroundStyle(.red).lineLimit(3)
            } else if let problem = role.problems.first {
                Text(problem).foregroundStyle(.secondary)
            } else {
                Text("Reusable in any rig once saved.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) {
                role.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save Role and Add Seat") {
                Task { if await role.save() { dismiss() } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(role.draft == nil || !role.problems.isEmpty || role.phase == .saving || role.phase == .drafting)
        }
    }
}

/// The draft's fields: name and summary, guidance, skills, and the role's default runtime, model and effort.
private struct DraftEditor: View {
    @Bindable var role: NewRoleStore

    var body: some View {
        if let draft = Binding($role.draft) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        field("Role name") {
                            TextField("Role name", text: draft.name).frame(width: 200)
                                .accessibilityLabel("Role name")
                        }
                        field("One-line summary (shown in the role library)") {
                            TextField("Summary", text: draft.summary).accessibilityLabel("Summary")
                        }
                    }
                    field("Guidance (role.md): what the seat reads when it starts") {
                        TextEditor(text: draft.guidance)
                            .font(.callout.monospaced())
                            .frame(minHeight: 260)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                            .accessibilityLabel("Guidance")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    skills(draft)
                    defaults(draft)
                    if let path = role.savedPath {
                        field("Saved as") {
                            Text(path + "/agent.yaml + guidance/role.md")
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
        }
    }

    private func skills(_ draft: Binding<RoleDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested skills").font(.subheadline.bold())
            if draft.wrappedValue.skills.isEmpty {
                Text("None suggested.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.skills) { $skill in
                let unknown = role.unknownSkills.contains(skill.id)
                Toggle(isOn: unknown ? .constant(false) : $skill.on) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.id).strikethrough(unknown)
                        Text(
                            unknown
                                ? "Not found in OpenRig, the project or your skills, so it won't be added." : skill.why
                        )
                        .font(.caption).foregroundStyle(unknown ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(unknown)
                .accessibilityLabel(skill.id + (unknown ? ", not found" : ""))
            }
        }
    }

    private func defaults(_ draft: Binding<RoleDraft>) -> some View {
        field("Default runtime, model and effort") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Runtime", selection: draft.runtime) {
                    ForEach(RoleDraft.runtimes, id: \.self) { Text(Runtime.label($0)).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Default runtime")
                TextField("Model (the runtime's default)", text: optional(draft.model))
                    .accessibilityLabel("Default model")
                TextField("Effort (the runtime's default)", text: optional(draft.effort))
                    .accessibilityLabel("Default effort")
            }
        }
    }

    /// An optional text as a field: blank is nil, so the spec leaves the key out.
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = ModelChoices.typed($0) })
    }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

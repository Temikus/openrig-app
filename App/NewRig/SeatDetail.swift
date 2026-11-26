import AppKit
import RigDomain
import SwiftUI

/// One seat of a new rig: what it reads when it starts, top to bottom, and its skills. Shared layers are read-only and
/// open in the person's editor; seat notes and added skills go to this seat only, as member startup files.
struct SeatDetail: View {
    let model: NewRigStore
    let seat: RigDraft.Seat

    var body: some View {
        let role = model.roles[seat.id] ?? "role"
        VStack(alignment: .leading, spacing: 14) {
            Button("‹ All seats") { model.detailSeat = nil }
                .buttonStyle(.link)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(seat.member).font(.title2.bold())
                Text(subtitle(role: role)).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    // An ideal width, so ViewThatFits doesn't measure each layer's line unwrapped.
                    SeatGuidanceList(model: model, seat: seat).frame(
                        minWidth: 380, idealWidth: 420, maxWidth: .infinity)
                    SeatSkills(model: model, seat: seat, role: role).frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 20) {
                    SeatGuidanceList(model: model, seat: seat)
                    SeatSkills(model: model, seat: seat, role: role)
                }
            }
            Divider()
            HStack {
                Text("Changes apply to this rig only. The \(role) role isn't changed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.detailSeat = nil }
            }
        }
    }

    private func subtitle(role: String) -> String {
        var parts = [role, seat.pod, Runtime.label(seat.runtime)]
        if let model = seat.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// The layers in the order OpenRig delivers them (`RigDraft.guidance`).
private struct SeatGuidanceList: View {
    let model: NewRigStore
    let seat: RigDraft.Seat
    @State private var open: Set<GuidanceLayer.Kind> = [.notes]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What \(seat.member) reads when it starts, top to bottom. Only seat notes are this seat's own.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.guidance(for: seat)) { layer in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { open.contains(layer.kind) },
                        set: { if $0 { open.insert(layer.kind) } else { open.remove(layer.kind) } })
                ) {
                    LayerBody(model: model, seat: seat, layer: layer)
                        .padding(.top, 6)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(layer.name).fontWeight(.semibold).frame(width: 96, alignment: .leading)
                        Text(layer.what).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 8)
                        Text(source(layer)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityLabel(layer.name)
            }
        }
    }
}

/// The layer's first file, and how many more.
private func source(_ layer: GuidanceLayer) -> String {
    guard let first = layer.files.first else { return "" }
    return layer.files.count > 1 ? "\(first.path) +\(layer.files.count - 1)" : first.path
}

private struct LayerBody: View {
    let model: NewRigStore
    let seat: RigDraft.Seat
    let layer: GuidanceLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if layer.isEditable {
                Text("Only \(seat.member) gets this. It's sent when the seat starts.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { seat.notes }, set: { model.setNotes($0, for: seat.id) }))
                    .font(.callout)
                    .frame(minHeight: 80, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Seat notes for \(seat.member)")
            } else if layer.files.isEmpty {
                Text("Nothing here yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(layer.files, id: \.url) { file in
                    SharedFile(file: file)
                }
                Text("Shared: Open File opens the source in your editor, so a change reaches every seat that reads it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A shared file's path, how it's delivered, a preview of its text, and Open File.
private struct SharedFile: View {
    let file: GuidanceFile

    var body: some View {
        let text = Self.preview(file.url)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(file.path).font(.caption.monospaced())
                Text(file.deliveryLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open File") { NSWorkspace.shared.open(file.url) }
                    .controlSize(.small)
                    .disabled(text == nil)
                    .help(file.url.path(percentEncoded: false))
                    .accessibilityLabel("Open \(file.path)")
            }
            Text(text ?? "Not found: \(file.url.path(percentEncoded: false))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background, in: .rect(cornerRadius: 6))
        }
    }

    /// The file's first lines.
    static func preview(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The role's skills, then this seat's own, and + Add Skill from the skills OpenRig can install.
private struct SeatSkills: View {
    let model: NewRigStore
    let seat: RigDraft.Seat
    let role: String
    @State private var adding = false
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Skills").font(.headline)
                Spacer()
                Button(adding ? "Close" : "+ Add Skill") { adding.toggle() }
                    .controlSize(.small)
                    .accessibilityLabel(adding ? "Close skill list" : "Add Skill")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.roleSkills(for: seat), id: \.self) { id in
                    row(id, from: "From role")
                }
                ForEach(seat.addedSkills) { skill in
                    row(skill.id, from: "Added for \(seat.member)") {
                        Button {
                            model.removeSkill(skill.id, from: seat.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(skill.id)")
                    }
                    .help(skill.summary ?? skill.folder.path(percentEncoded: false))
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            if adding { picker }
            Text(
                "Skills from the role come with every \(role). Ones you add go only to \(seat.member), installed when "
                    + "it starts. OpenRig installs a skill's SKILL.md, not the other files in its folder."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        let choices = model.skillChoices(for: seat).filter {
            filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter)
        }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Filter skills", text: $filter)
                .textFieldStyle(.roundedBorder)
            if choices.isEmpty {
                Text("No other skills found.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choices) { skill in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(skill.id)
                                Text(skill.source.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { model.addSkill(skill, to: seat.id) }
                                .controlSize(.small)
                                .accessibilityLabel("Add \(skill.id)")
                        }
                        .help(skill.summary ?? "")
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func row(_ name: String, from: String) -> some View {
        row(name, from: from) { EmptyView() }
    }

    private func row(_ name: String, from: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                Text(from).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

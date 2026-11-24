import AppKit
import QuickLook
import QuickLookThumbnailing
import RigDomain
import RigModel
import SwiftUI

extension EnvironmentValues {
    /// The selected row's images, found by QItemInspector once it shows; nil while they load.
    @Entry var rowImages: RowImages?
}

/// What a row points at: a thumbnail of each image, which opens in Quick Look. A row without images keeps its
/// evidence line where `showsLine` (the For You panel) and shows nothing elsewhere, as before.
struct RowEvidence: View {
    let item: QItem
    var title: String?
    var showsLine = true
    @Environment(\.rowImages) private var found
    @State private var preview: URL?

    /// More would push the questions far down; Quick Look still steps through all of them.
    static let cap = 12

    var body: some View {
        if let found, !found.images.isEmpty {
            thumbnails(found.images)
        } else if showsLine, found != nil, let ref = item.evidenceRef {
            EvidenceLine(ref: ref, file: found?.evidence)
        }
    }

    private func thumbnails(_ images: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.headline) }
            LazyVGrid(
                // Two to a line in the inspector's usual width; boards are about 2.6 times wider than tall.
                columns: [GridItem(.adaptive(minimum: 90, maximum: 220), spacing: 8, alignment: .top)],
                alignment: .leading, spacing: 8
            ) {
                ForEach(images.prefix(Self.cap), id: \.self) { url in
                    Thumbnail(url: url) { preview = url }
                }
            }
            if images.count > Self.cap {
                Text("\(images.count - Self.cap) more. Open one and use the arrow keys to see them all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .quickLookPreview($preview, in: images)
    }
}

/// One image as a button: its picture scaled down, and its file name, which the asker's questions refer to.
private struct Thumbnail: View {
    let url: URL
    let open: () -> Void
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    nonisolated static let height: CGFloat = 52
    private var name: String { url.deletingPathExtension().lastPathComponent }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                    if let image {
                        Image(decorative: image, scale: scale).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipShape(.rect(cornerRadius: 6))
                Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityHint("Opens in Quick Look")
        .help(url.path)
        .task(id: url) { image = await Self.thumbnail(of: url, scale: scale) }
    }

    /// Quick Look draws it off the main thread at the size shown, so a 6000 px board is never loaded whole.
    nonisolated static func thumbnail(of url: URL, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 220, height: height), scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// The artifact the agent asked the person to judge, when it isn't an image: a file opens in its app; anything else
/// is shown to copy.
struct EvidenceLine: View {
    let ref: String
    /// Found on disk by `RowImages`, so a relative path opens too.
    var file: URL?

    /// With a remote daemon nothing is looked up, and an absolute path is checked here as before.
    private var openable: URL? {
        if let file { return file }
        guard ref.hasPrefix("/") else { return nil }
        let url = URL(filePath: ref)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        let file = openable
        HStack(spacing: 6) {
            Image(systemName: file == nil ? "text.quote" : "doc.text").foregroundStyle(.secondary)
            Text(file?.lastPathComponent ?? ref)
                .font(file == nil ? .caption : .caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(ref)
            Spacer()
            if let file {
                Button("Open") { NSWorkspace.shared.open(file) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

import Foundation

/// The images a queue row points at on this Mac, from its `evidenceRef` and body.
/// Foundation only: the kit also builds for iOS.
public struct RowImages: Equatable, Sendable {
    /// Grouped by folder, folders in the order first named (`evidenceRef` first), names in number order.
    public var images: [URL] = []
    /// `evidenceRef` names something on disk that gives no image. The inspector keeps its line with Open.
    public var evidence: URL?

    public init(images: [URL] = [], evidence: URL? = nil) {
        self.images = images
        self.evidence = evidence
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp",
    ]

    /// Reads the disk: call it off the main thread.
    /// - Parameters:
    ///   - launchFolder: the source seat's `launch_cwd`. Relative paths resolve against it; without it they are ignored.
    ///   - local: the daemon runs on this Mac. A remote daemon's paths name another machine's files, so nothing is read.
    public static func find(
        evidenceRef: String?, body: String?, launchFolder: String?, local: Bool, home: String = NSHomeDirectory()
    ) -> RowImages {
        guard local else { return RowImages() }
        var found = Found()
        var evidence: URL?
        let ref = evidenceRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = resolve(ref, launchFolder: launchFolder, home: home), found.add(url) == .nothing {
            evidence = url
        }
        for path in paths(in: body ?? "") {
            if let url = resolve(path, launchFolder: launchFolder, home: home) { _ = found.add(url) }
        }
        return RowImages(images: found.images, evidence: evidence)
    }

    /// An absolute path, a `~/` path, or one relative to the launch folder, if it exists. Symlinks are resolved so a
    /// file reached two ways is one file.
    static func resolve(_ path: String, launchFolder: String?, home: String) -> URL? {
        guard !path.isEmpty, !path.contains("://") else { return nil }
        let full: String
        if path.hasPrefix("/") {
            full = path
        } else if path.hasPrefix("~/") {
            full = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("~") {
            return nil
        } else if let launchFolder {
            full = (launchFolder as NSString).appendingPathComponent(path)
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: full) else { return nil }
        return URL(fileURLWithPath: full).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Candidate paths in the order written: each `backtick` span whole, and outside them each run without spaces that
    /// contains "/". Brackets, quotes and trailing punctuation around a run are dropped.
    static func paths(in body: String) -> [String] {
        var out: [String] = []
        let parts = body.split(separator: "`", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            // Odd parts sit between two backticks; a last odd part has no closing one.
            if i % 2 == 1, i < parts.count - 1 {
                let span = part.trimmingCharacters(in: .whitespaces)
                if !span.isEmpty, !span.contains("\n") { out.append(span) }
                continue
            }
            for run in part.split(whereSeparator: \.isWhitespace) where run.contains("/") {
                let trimmed = run.drop { "([{<\"'*".contains($0) }
                let path = String(trimmed.reversed().drop { ".,;:!?)]}>\"'*".contains($0) }.reversed())
                if !path.isEmpty { out.append(path) }
            }
        }
        return out
    }
}

/// Images gathered so far, grouped by the folder that holds them.
private struct Found {
    enum Added { case images, nothing }

    private var folders: [String] = []
    private var byFolder: [String: [URL]] = [:]
    private var seen: Set<String> = []

    var images: [URL] {
        folders.flatMap { folder in
            byFolder[folder, default: []].sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive])
                    == .orderedAscending
            }
        }
    }

    /// A folder adds the images directly inside it; a file adds itself if it is an image.
    mutating func add(_ url: URL) -> Added {
        if isFolder(url) {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let images = entries.filter { isImage($0) && !isFolder($0) }.map { $0.resolvingSymlinksInPath() }
            return insert(images, in: url.path)
        }
        guard isImage(url) else { return .nothing }
        return insert([url], in: url.deletingLastPathComponent().path)
    }

    private mutating func insert(_ images: [URL], in folder: String) -> Added {
        guard !images.isEmpty else { return .nothing }
        if byFolder[folder] == nil { folders.append(folder) }
        for image in images where seen.insert(image.path).inserted {
            byFolder[folder, default: []].append(image)
        }
        return .images
    }

    private func isImage(_ url: URL) -> Bool {
        RowImages.imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}

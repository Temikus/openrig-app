import Foundation
import Testing

@testable import RigDomain

/// Every test builds real files in its own temporary folder.
@Suite final class RowImagesTests {
    let root: URL
    let checkout: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "row-images-\(UUID().uuidString)")
        checkout = root.appending(path: "checkout")
        home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes empty files at `paths` under `base`, making folders as needed. A path ending in "/" is a folder.
    func make(_ paths: [String], in base: URL? = nil) throws {
        for path in paths {
            let url = (base ?? checkout).appending(path: path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
        }
    }

    func find(
        _ ref: String?, body: String? = nil, launch: String? = nil, local: Bool = true, home: String? = nil
    ) -> RowImages {
        RowImages.find(
            evidenceRef: ref, body: body, launchFolder: launch ?? checkout.path, local: local,
            home: home ?? self.home.path)
    }

    static let boards = ["1-app-shape.png", "2-question-screen.png", "3-first-launch.png", "4-mac-pairing.png"]

    /// q-f0af as written: `evidenceRef` names board 2, and the body names the boards' folder.
    @Test func theFourBoardsOfQf0af() throws {
        try make(Self.boards.map { ".claude/plans/ios-remote/mockups/\($0)" })
        let body = """
            The designer drew the four visual questions for the iOS remote's first version. Paper page "iOS remote · \
            options" in "OpenRig — Canvas prototype"; PNGs in .claude/plans/ios-remote/mockups/ (1-app-shape, \
            2-question-screen, 3-first-launch, 4-mac-pairing). The planner, the designer and I all pick A on every board.
            """
        let found = find(".claude/plans/ios-remote/mockups/2-question-screen.png", body: body)
        #expect(found.images.map(\.lastPathComponent) == Self.boards)
        #expect(found.evidence == nil)
    }

    @Test func absoluteHomeAndRelativePaths() throws {
        try make(["a.png"], in: root.appending(path: "elsewhere"))
        try make(["Desktop/b.png"], in: home)
        try make(["shots/c.png"])
        let absolute = root.appending(path: "elsewhere/a.png").path
        #expect(find(absolute).images.map(\.lastPathComponent) == ["a.png"])
        #expect(find("~/Desktop/b.png").images.map(\.path).first?.hasSuffix("/home/Desktop/b.png") == true)
        #expect(find("shots/c.png").images.map(\.path).first?.hasSuffix("/checkout/shots/c.png") == true)
        #expect(find("~user/Desktop/b.png") == RowImages())
    }

    @Test func aFolderGivesItsImagesInNumberOrder() throws {
        try make(["shots/10-a.png", "shots/2-b.jpg", "shots/notes.txt", "shots/.hidden.png", "shots/sub/d.png"])
        try make(["shots/folder.png/"])
        let found = find("shots")
        #expect(found.images.map(\.lastPathComponent) == ["2-b.jpg", "10-a.png"])
        #expect(found.evidence == nil)
    }

    @Test func pathsInTheBody() throws {
        try make(["bare/a.png", "my shots/b.png", "dot/c.png", "paren/d.png", "folder/e.png", "folder/f.png"])
        let body = """
            See bare/a.png and `my shots/b.png`. Then dot/c.png. (also paren/d.png) and the folder folder/
            Not https://example.com/x/y.png, not missing/z.png, not `missing two/w.png`.
            """
        let found = find(nil, body: body)
        #expect(found.images.map(\.lastPathComponent) == ["a.png", "b.png", "c.png", "d.png", "e.png", "f.png"])
    }

    /// The lead's launch folder, `~/iCloud/…`, is a symlink: the same board named through it and directly shows once.
    @Test func aFileReachedTwoWaysShowsOnce() throws {
        try make(["mockups/1.png", "mockups/2.png"])
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: checkout)
        let direct = checkout.appending(path: "mockups/2.png").path
        let found = find("mockups/2.png", body: "Board two: \(direct), all: mockups/", launch: link.path)
        #expect(found.images.map(\.lastPathComponent) == ["1.png", "2.png"])
    }

    @Test func folderGroupsKeepTheOrderTheyAreNamed() throws {
        try make(["later/1.png", "first/2.png", "first/3.png"])
        let found = find("first/3.png", body: "later/ and first/")
        #expect(found.images.map(\.lastPathComponent) == ["2.png", "3.png", "1.png"])
    }

    /// Rule 6: today's line with Open, now for a relative path too.
    @Test func anEvidenceFileThatIsNotAnImage() throws {
        try make(["docs/report.md"])
        let found = find("docs/report.md")
        #expect(found.images.isEmpty)
        #expect(found.evidence?.lastPathComponent == "report.md")
    }

    /// Rule 7: today's text line.
    @Test func anEvidenceRefThatNamesNothing() {
        let found = find("https://github.com/Temikus/openrig-app/pull/5")
        #expect(found == RowImages())
        #expect(find("missing/z.png") == RowImages())
    }

    /// Rule 9: the source seat is gone, so only absolute and `~/` paths resolve.
    @Test func withoutALaunchFolder() throws {
        try make(["shots/a.png"])
        try make(["b.png"], in: home)
        let absolute = checkout.appending(path: "shots/a.png").path
        let found = RowImages.find(
            evidenceRef: "shots/a.png", body: "\(absolute) and ~/b.png", launchFolder: nil, local: true,
            home: home.path)
        #expect(found.images.map(\.lastPathComponent) == ["a.png", "b.png"])
    }

    /// Rule 8: a remote daemon's paths name another machine's files.
    @Test func aRemoteDaemonReadsNothing() throws {
        try make(["shots/a.png", "docs/report.md"])
        #expect(find("shots/a.png", body: "docs/report.md shots/", local: false) == RowImages())
        #expect(find("docs/report.md", local: false) == RowImages())
    }
}

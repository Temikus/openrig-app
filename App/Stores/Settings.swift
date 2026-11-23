import AppKit
import Foundation
import Observation
import RigDomain

/// Everything in the Settings window, saved to UserDefaults as it changes. The operator token is the exception: it
/// lives in the Keychain (`OperatorToken`).
@MainActor @Observable
final class AppSettings {
    enum OpenTo: String, CaseIterable, Identifiable {
        case canvas, queue, terminals, lastUsed
        var id: Self { self }
        var title: String {
            switch self {
            case .canvas: ViewMode.canvas.title
            case .queue: ViewMode.queue.title
            case .terminals: ViewMode.terminals.title
            case .lastUsed: "Last used"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    enum BannerScope: String, CaseIterable, Identifiable {
        case allRigs, openRig
        var id: Self { self }
        var title: String { self == .allRigs ? "All rigs" : "The open rig" }
    }

    @ObservationIgnored private let defaults: UserDefaults

    // General
    var openTo: OpenTo { didSet { save(openTo.rawValue, "openTo") } }
    var reopenLastRig: Bool { didSet { save(reopenLastRig, "reopenLastRig") } }
    var dockBadge: Bool { didSet { save(dockBadge, "dockBadge") } }
    /// `MenuBarExtra(isInserted:)` writes its value back at launch. Saving only changes keeps "never set" unset.
    var menuBarItem: Bool { didSet { if menuBarItem != oldValue { save(menuBarItem, "menuBarItem") } } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    /// Written as the person moves around; read by "Open to" and "Reopen the last rig".
    var lastRigName: String? { didSet { save(lastRigName, "lastRigName") } }
    var lastView: ViewMode { didSet { save(lastView.rawValue, "lastView") } }
    /// A person registered with the gateway, or `human@host`. Nil means the gateway's default person.
    var actAs: String? { didSet { save(actAs, "actAs") } }

    // Connection
    /// Nil means find the daemon the way the CLI does.
    var customAddress: URL? { didSet { save(customAddress?.absoluteString, "customAddress") } }
    var rigPath: URL? { didSet { save(rigPath?.path, "rigPath") } }
    var tmuxPath: URL? { didSet { save(tmuxPath?.path, "tmuxPath") } }
    var nodePath: URL? { didSet { save(nodePath?.path, "nodePath") } }

    // Notifications
    var bannerKinds: Set<NoticeKind> {
        didSet { save(bannerKinds.map(\.rawValue).sorted(), "bannerKinds") }
    }
    var bannersOnlyInBackground: Bool { didSet { save(bannersOnlyInBackground, "bannersOnlyInBackground") } }
    var bannerScope: BannerScope { didSet { save(bannerScope.rawValue, "bannerScope") } }
    /// A system sound name, or "" for none.
    var promptSound: String { didSet { save(promptSound, "promptSound") } }

    // Terminals
    var typeOnFocus: Bool { didSet { save(typeOnFocus, "typeOnFocus") } }
    var escGoesToPane: Bool { didSet { save(escGoesToPane, "escGoesToPane") } }
    var optionAsMeta: Bool { didSet { save(optionAsMeta, "optionAsMeta") } }
    /// Tiles shrink text to fit a pane down to this size, then clip the right edge.
    var smallestTileText: Double { didSet { save(smallestTileText, "smallestTileText") } }

    static let smallestTileTextRange = 7.0...12.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openTo = defaults.string(forKey: "openTo").flatMap(OpenTo.init) ?? .canvas
        reopenLastRig = defaults.object(forKey: "reopenLastRig") as? Bool ?? true
        dockBadge = defaults.object(forKey: "dockBadge") as? Bool ?? true
        // Absent means on. `bool(forKey:)` also reads a `-menuBarItem NO` launch argument, which is a string.
        menuBarItem = defaults.object(forKey: "menuBarItem") == nil || defaults.bool(forKey: "menuBarItem")
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init) ?? .system
        lastRigName = defaults.string(forKey: "lastRigName")
        lastView = defaults.string(forKey: "lastView").flatMap(ViewMode.init) ?? .canvas
        actAs = defaults.string(forKey: "actAs")
        customAddress = defaults.string(forKey: "customAddress").flatMap(URL.init(string:))
        rigPath = defaults.string(forKey: "rigPath").map { URL(filePath: $0) }
        tmuxPath = defaults.string(forKey: "tmuxPath").map { URL(filePath: $0) }
        nodePath = defaults.string(forKey: "nodePath").map { URL(filePath: $0) }
        bannerKinds =
            (defaults.stringArray(forKey: "bannerKinds")?.compactMap(NoticeKind.init)).map(Set.init)
            ?? Set(NoticeKind.allCases)
        bannersOnlyInBackground = defaults.object(forKey: "bannersOnlyInBackground") as? Bool ?? true
        bannerScope = defaults.string(forKey: "bannerScope").flatMap(BannerScope.init) ?? .allRigs
        promptSound = defaults.string(forKey: "promptSound") ?? "Glass"
        typeOnFocus = defaults.bool(forKey: "typeOnFocus")
        escGoesToPane = defaults.bool(forKey: "escGoesToPane")
        optionAsMeta = defaults.object(forKey: "optionAsMeta") as? Bool ?? true
        smallestTileText = defaults.object(forKey: "smallestTileText") as? Double ?? 8.5
    }

    /// The view to open at launch.
    var launchView: ViewMode {
        switch openTo {
        case .canvas: .canvas
        case .queue: .queue
        case .terminals: .terminals
        case .lastUsed: lastView
        }
    }

    func bannerBinding(_ kind: NoticeKind) -> Bool { bannerKinds.contains(kind) }

    func setBanner(_ kind: NoticeKind, _ on: Bool) {
        if on { bannerKinds.insert(kind) } else { bannerKinds.remove(kind) }
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

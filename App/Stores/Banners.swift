import AppKit
import RigDomain
import UserNotifications

/// Posts macOS banners for new things waiting on the person (see `Notices`), and opens the app at the right place when
/// one is clicked. Banners carry no actions: clicking opens the prompt, it never answers it.
@MainActor
final class Banners: NSObject, UNUserNotificationCenterDelegate {
    private var tracker = NoticeTracker()
    private weak var store: AppStore?
    private var asked = false

    init(store: AppStore) {
        self.store = store
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Diffs what waits now against last time and posts what's new and enabled.
    func check() async {
        guard let store else { return }
        let settings = store.settings
        var current: [Notice] = []
        if let rig = store.rig { current += notices(entries: rig.needsYou, rig: rig.rigName, me: store.me) }
        if settings.bannerScope == .allRigs {
            current += store.elsewhere.compactMap { notice(for: $0, me: store.me) }
            current += attentionNotices(
                Dictionary(store.attentionElsewhere.map { ($0.rig, $0.count) }, uniquingKeysWith: +))
        }
        if case .unreachable(_, let since) = store.daemon, let down = daemonDownNotice(since: since, now: .now) {
            current.append(down)
        }
        // Other rigs' counts are prompts too, so they follow the permission switch.
        var enabled = settings.bannerKinds
        if enabled.contains(.permission) { enabled.insert(.otherRig) } else { enabled.remove(.otherRig) }

        let fresh = tracker.update(current, enabled: enabled)
        guard !fresh.isEmpty else { return }
        if settings.bannersOnlyInBackground, NSApp.isActive, store.windowInFront {
            Self.debugLog("held: window in front (\(fresh.count))")
            return
        }
        let allowed = await authorized()
        Self.debugLog("fresh \(fresh.count), authorized \(allowed)")
        guard allowed else { return }
        for notice in fresh { post(notice, sound: settings.promptSound) }
    }

    /// OPENRIG_DEBUG_BANNERS=<file>: one line per decision and per banner posted.
    nonisolated static func debugLog(_ line: String) {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_BANNERS"] else { return }
            let text = "\(line)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        #endif
    }

    private func authorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        Self.debugLog("authorization status \(status.rawValue)")
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined where !asked:
            asked = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.debugLog("authorization failed: \(error)")
                return false
            }
        default: return false
        }
    }

    private func post(_ notice: Notice, sound: String) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = Self.encode(notice.target)
        // System sounds aren't in the app bundle, so the app plays the permission sound itself.
        if notice.kind == .permission || notice.kind == .otherRig, !sound.isEmpty { NSSound(named: sound)?.play() }
        let request = UNNotificationRequest(identifier: notice.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Self.debugLog(
                "\(notice.kind.rawValue) | \(notice.title) | \(notice.body) | \(error.map { "\($0)" } ?? "ok")")
        }
    }

    private static func encode(_ target: NoticeTarget) -> [String: String] {
        switch target {
        case .seat(let rig, let session): ["target": "seat", "rig": rig, "session": session]
        case .qitem(let id): ["target": "qitem", "id": id]
        case .rig(let rig): ["target": "rig", "rig": rig]
        case .app: ["target": "app"]
        }
    }

    nonisolated private static func decode(_ info: [AnyHashable: Any]) -> NoticeTarget {
        let value = { (key: String) in info[key] as? String ?? "" }
        switch value("target") {
        case "seat": return .seat(rig: value("rig"), session: value("session"))
        case "qitem": return .qitem(value("id"))
        case "rig": return .rig(value("rig"))
        default: return .app
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let target = Self.decode(info)
        Self.debugLog("clicked: \(target)")
        await MainActor.run { store?.show(target) }
    }

    /// Shown even while the app is frontmost, when "Only when the window is closed or behind" is off.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

import AppKit

/// Speaks `text` through VoiceOver or another assistive app; nothing happens when none is running.
@MainActor func announce(_ text: String, urgent: Bool = false) {
    let priority: NSAccessibilityPriorityLevel = urgent ? .high : .medium
    NSAccessibility.post(
        element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: priority.rawValue])
}

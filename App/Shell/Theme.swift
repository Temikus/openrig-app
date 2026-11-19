import AppKit
import SwiftUI

extension Color {
    /// "Needs you": a soft coral in dark mode, a deeper red in light mode for contrast on white.
    static let attention = Color(
        nsColor: NSColor(name: "attention") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.88, green: 0.46, blue: 0.39, alpha: 1)
                : NSColor(srgbRed: 0.78, green: 0.25, blue: 0.20, alpha: 1)
        })

    /// Fill behind white text on a count badge: deep enough for 4.5:1 in both appearances, where `attention`'s soft
    /// dark-mode coral isn't.
    static let attentionFill = Color(.sRGB, red: 0.76, green: 0.26, blue: 0.21)

    /// The grey badge for FYIs only: white on it is about 5:1, where white on `Color.secondary` was about 3.3:1.
    static let quietFill = Color(white: 0.42)

    /// "Approved": system green is too light for text on white, so light mode gets a deeper one.
    static let approved = Color(
        nsColor: NSColor(name: "approved") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .systemGreen
                : NSColor(srgbRed: 0.09, green: 0.48, blue: 0.20, alpha: 1)
        })

    /// Terminal tile body, the same in both appearances: panes are drawn light-on-dark.
    static let terminalBody = Color(white: 0.08)

    /// Terminal tile header and footer: one step lighter than the window in dark mode.
    static let tileChrome = Color(nsColor: .controlBackgroundColor)
}

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

    /// Terminal tile body, the same in both appearances: panes are drawn light-on-dark.
    static let terminalBody = Color(white: 0.08)

    /// Terminal tile header and footer: one step lighter than the window in dark mode.
    static let tileChrome = Color(nsColor: .controlBackgroundColor)
}

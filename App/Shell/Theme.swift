import AppKit
import SwiftUI

extension Color {
    /// A colour per appearance, with stronger variants for Settings › Accessibility › Increase Contrast.
    static func adaptive(
        _ name: String, dark: NSColor, light: NSColor, darkHighContrast: NSColor? = nil,
        lightHighContrast: NSColor? = nil
    ) -> Color {
        Color(
            nsColor: NSColor(name: NSColor.Name(name)) { appearance in
                switch appearance.bestMatch(from: [
                    .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
                ]) {
                case .accessibilityHighContrastDarkAqua?: darkHighContrast ?? dark
                case .accessibilityHighContrastAqua?: lightHighContrast ?? light
                case .darkAqua?: dark
                default: light
                }
            })
    }

    /// "Needs you": a soft coral in dark mode, a deeper red in light mode for contrast on white.
    /// The dark coral is bright enough for 4.5:1 as caption text on the coral-tinted tile and card headers.
    static let attention = adaptive(
        "attention", dark: NSColor(srgbRed: 0.93, green: 0.53, blue: 0.46, alpha: 1),
        light: NSColor(srgbRed: 0.78, green: 0.25, blue: 0.20, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 1.0, green: 0.66, blue: 0.60, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.62, green: 0.14, blue: 0.10, alpha: 1))

    /// Fill behind white text on a count badge: deep enough for 4.5:1 in both appearances, where `attention`'s soft
    /// dark-mode coral isn't.
    static let attentionFill = adaptive(
        "attentionFill", dark: NSColor(srgbRed: 0.76, green: 0.26, blue: 0.21, alpha: 1),
        light: NSColor(srgbRed: 0.76, green: 0.26, blue: 0.21, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 0.62, green: 0.15, blue: 0.11, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.62, green: 0.15, blue: 0.11, alpha: 1))

    /// The grey badge for FYIs only: white on it is about 5:1, where white on `Color.secondary` was about 3.3:1.
    static let quietFill = adaptive(
        "quietFill", dark: NSColor(white: 0.42, alpha: 1), light: NSColor(white: 0.42, alpha: 1),
        darkHighContrast: NSColor(white: 0.30, alpha: 1), lightHighContrast: NSColor(white: 0.30, alpha: 1))

    /// "Approved": system green is too light for text on white, so light mode gets a deeper one. System green has
    /// its own high-contrast variant.
    static let approved = adaptive(
        "approved", dark: .systemGreen, light: NSColor(srgbRed: 0.09, green: 0.48, blue: 0.20, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.05, green: 0.36, blue: 0.13, alpha: 1))

    /// "Look at this" as text (a degraded rig's sidebar line). System orange is about 1.8:1 on the light sidebar, so
    /// light mode gets a burnt orange; the bright orange stays for dots.
    static let lookText = adaptive(
        "lookText", dark: .systemOrange, light: NSColor(srgbRed: 0.66, green: 0.29, blue: 0.0, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.52, green: 0.22, blue: 0.0, alpha: 1))

    /// Work that is moving (in-flight and next-hop wires, an active item's dot): the green of a working seat. Orange
    /// is kept for things that need a look (overdue, down, changed).
    static let moving = Color.green

    /// Captions on prompt cards ("wants to run"): `.secondary` fell to about 3.2:1 on the coral tint behind them.
    static let promptCaption = Color.primary.opacity(0.75)

    /// Terminal tile body, the same in both appearances: panes are drawn light-on-dark.
    static let terminalBody = Color(white: 0.08)

    /// Secondary text on the always-dark tile body (`.secondary` would follow a light appearance and vanish).
    static let tileSecondary = adaptive(
        "tileSecondary", dark: NSColor(white: 0.65, alpha: 1), light: NSColor(white: 0.65, alpha: 1),
        darkHighContrast: NSColor(white: 0.82, alpha: 1), lightHighContrast: NSColor(white: 0.82, alpha: 1))

    /// Terminal tile header and footer: one step lighter than the window in dark mode.
    static let tileChrome = Color(nsColor: .controlBackgroundColor)
}

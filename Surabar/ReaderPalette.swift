import AppKit
import SwiftUI

/// Theme and accent colours. System, Light, and Dark follow the window appearance; Sepia uses fixed colours.
struct ReaderPalette {
    let theme: ReaderTheme
    let accentChoice: ReaderAccent
    let customAccent: AccentRGB

    init(theme: ReaderTheme, accent: ReaderAccent = .system, customAccent: AccentRGB = .default) {
        self.theme = theme
        accentChoice = accent
        self.customAccent = customAccent
    }

    @MainActor init(state: AppState) {
        self.init(theme: state.theme, accent: state.accent, customAccent: state.customAccent)
    }

    /// Sepia's own accent, used there when the accent follows the system.
    static let sepiaAccent = NSColor(srgbRed: 0.478, green: 0.306, blue: 0.114, alpha: 1)

    var chrome: Color { theme == .sepia ? Color(red: 0.933, green: 0.894, blue: 0.812) : Color(nsColor: .windowBackgroundColor) }
    var page: Color { theme == .sepia ? Color(red: 0.973, green: 0.941, blue: 0.871) : Color(nsColor: .textBackgroundColor) }
    var ink: Color { theme == .sepia ? Color(red: 0.18, green: 0.141, blue: 0.086) : .primary }
    var secondary: Color { theme == .sepia ? Color(red: 0.416, green: 0.353, blue: 0.259) : .secondary }
    var accent: Color { Color(nsColor: accentColor) }

    /// The accent as an AppKit colour; the system colours adapt to light and dark appearances.
    var accentColor: NSColor {
        Self.color(for: accentChoice, custom: customAccent, sepia: theme == .sepia)
    }

    /// Text and symbols drawn on the accent: black on light accents such as yellow, otherwise white.
    var onAccent: Color {
        guard let rgb = accentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? .black : .white
    }

    static func color(for accent: ReaderAccent, custom: AccentRGB, sepia: Bool = false) -> NSColor {
        switch accent {
        case .system: sepia ? sepiaAccent : .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        case .custom: NSColor(srgbRed: custom.red, green: custom.green, blue: custom.blue, alpha: 1)
        }
    }
}

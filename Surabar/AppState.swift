import Foundation
import MushafRendering
import Observation

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }
}

/// State shared by the popover, the detached window, the menus, and Settings.
/// Preferences persist in UserDefaults; the detached window's frame is saved by AppKit.
@MainActor
@Observable
final class AppState {
    private enum Keys {
        static let size = "readerSize"
        static let theme = "readerTheme"
        static let keepOnTop = "keepDetachedWindowOnTop"
        static let detached = "readerDetached"
        static let translation = "showTranslation"
        static let script = "readingScript"
        static let pages = "readingPages"
        static let selection = "selectedAyah"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var size: ReaderSize {
        didSet { defaults.set(size.rawValue, forKey: Keys.size) }
    }

    var theme: ReaderTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var keepOnTop: Bool {
        didSet { defaults.set(keepOnTop, forKey: Keys.keepOnTop) }
    }

    /// Whether the reader lives in a floating window instead of the menu bar popover.
    var isDetached: Bool {
        didSet { defaults.set(isDetached, forKey: Keys.detached) }
    }

    var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.translation) }
    }

    /// The layout being read: "uthmani" or "indopak".
    var script: String {
        didSet { defaults.set(script, forKey: Keys.script) }
    }

    /// The last page read in each layout. Page numbers are per layout and never identify an ayah.
    var pages: [String: Int] {
        didSet { defaults.set(pages, forKey: Keys.pages) }
    }

    /// The selected ayah, stored as "surah:ayah".
    var selectedAyah: AyahKey {
        didSet { defaults.set(selectedAyah.description, forKey: Keys.selection) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = defaults.string(forKey: Keys.size).flatMap(ReaderSize.init(rawValue:)) ?? .medium
        theme = defaults.string(forKey: Keys.theme).flatMap(ReaderTheme.init(rawValue:)) ?? .system
        keepOnTop = defaults.object(forKey: Keys.keepOnTop) as? Bool ?? true
        isDetached = defaults.bool(forKey: Keys.detached)
        showTranslation = defaults.object(forKey: Keys.translation) as? Bool ?? true
        script = defaults.string(forKey: Keys.script) ?? "uthmani"
        pages = defaults.dictionary(forKey: Keys.pages) as? [String: Int] ?? [:]
        selectedAyah = defaults.string(forKey: Keys.selection).flatMap(AyahKey.init(string:)) ?? AyahKey(surah: 1, ayah: 1)
    }
}

extension ReaderSize {
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The key that selects this size in the reader and the status menu.
    var shortcut: String {
        switch self {
        case .small: "1"
        case .medium: "2"
        case .large: "3"
        }
    }
}

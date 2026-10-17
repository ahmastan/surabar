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

/// What the reader window shows. Chosen in Settings › General.
enum ReaderViewMode: String, CaseIterable, Identifiable {
    case quranAndPlayer = "quran", playerOnly = "player"

    var id: Self { self }

    var title: String {
        switch self {
        case .quranAndPlayer: "Quran + player"
        case .playerOnly: "Player only"
        }
    }
}

/// How far the player's outer skip buttons move.
enum SkipUnit: String, CaseIterable, Identifiable {
    case page, surah

    var id: Self { self }

    var title: String {
        switch self {
        case .page: "Page"
        case .surah: "Surah"
        }
    }
}

/// Where playback stops when no loop is on (Settings › Player).
enum PlaybackStop: String, CaseIterable, Identifiable {
    case page, surah, juz, quran

    var id: Self { self }

    var title: String {
        switch self {
        case .page: "Page"
        case .surah: "Surah"
        case .juz: "Juz"
        case .quran: "End of Quran"
        }
    }
}

/// The Loop button's modes, cycled in this order. `unit` repeats the surah or page, following the skip unit.
/// `range` (ayah X to Y) is set from the ayah menu; cycling from it turns the loop off.
enum LoopMode: String, CaseIterable, Identifiable {
    case off, ayah, unit, range

    var id: Self { self }

    var next: LoopMode {
        switch self {
        case .off: .ayah
        case .ayah: .unit
        case .unit, .range: .off
        }
    }

    func title(unit: SkipUnit) -> String {
        switch self {
        case .off: "Off"
        case .ayah: "Ayah"
        case .unit: unit.title
        case .range: "Range"
        }
    }
}

extension ClosedRange where Bound == AyahKey {
    /// "2:255–257" within a surah, "2:286–3:2" across surahs.
    var title: String {
        lowerBound.surah == upperBound.surah ? "\(lowerBound)–\(upperBound.ayah)" : "\(lowerBound)–\(upperBound)"
    }

    /// Stored as "2:255-2:257".
    var stored: String { "\(lowerBound)-\(upperBound)" }

    init?(stored: String) {
        let parts = stored.split(separator: "-").compactMap { AyahKey(string: String($0)) }
        guard parts.count == 2, parts[0] <= parts[1] else { return nil }
        self = parts[0] ... parts[1]
    }
}

/// The accent colour: the system's, one of the eight macOS accent colours, or a custom colour.
enum ReaderAccent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite, custom

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Follow system"
        case .custom: "Custom"
        default: rawValue.capitalized
        }
    }
}

/// A custom accent colour in sRGB, stored as "#RRGGBB".
struct AccentRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let `default` = AccentRGB(red: 0.18, green: 0.545, blue: 0.478)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

/// The menu bar icon: the app icon's mark (default), the mark on a tile, or a matching system symbol.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case surabar, tile, book, closedBook, moon, waveform

    var id: Self { self }

    var title: String {
        switch self {
        case .surabar: "Surabar"
        case .tile: "Surabar tile"
        case .book: "Book"
        case .closedBook: "Closed book"
        case .moon: "Moon and stars"
        case .waveform: "Waveform"
        }
    }

    /// An image in the asset catalog, drawn from the app icon.
    var assetName: String? {
        switch self {
        case .surabar: "MenuBarIcon"
        case .tile: "MenuBarTile"
        default: nil
        }
    }

    var symbolName: String {
        switch self {
        case .surabar, .tile: "book"
        case .book: "book"
        case .closedBook: "text.book.closed"
        case .moon: "moon.stars"
        case .waveform: "waveform"
        }
    }
}

/// The Settings tabs, in order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance, reading, player, general

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .reading: "book"
        case .player: "play.circle"
        case .general: "gearshape"
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
        static let menuBarIcon = "menuBarIcon"
        static let accent = "accentColor"
        static let customAccent = "customAccentColor"
        static let viewMode = "viewMode"
        static let skipUnit = "skipUnit"
        static let repeatCount = "loopRepeatCount"
        static let loopMode = "loopMode"
        static let playbackStop = "playbackStop"
        static let loopRange = "loopRange"
        static let cacheBudget = "audioCacheBudget"
        static let keepOnTop = "keepDetachedWindowOnTop"
        static let detached = "readerDetached"
        static let translation = "showTranslation"
        static let script = "readingScript"
        static let pages = "readingPages"
        static let selection = "selectedAyah"
        static let reciter = "mp3quranReciter"
        static let speed = "playbackSpeed"
        static let repeatPause = "repeatPause"
        static let lastPlayed = "lastPlayedAyah"
    }

    @ObservationIgnored private let defaults: UserDefaults

    #if DEBUG
    /// For tests that reopen the same settings.
    var debugDefaults: UserDefaults { defaults }
    #endif

    var size: ReaderSize {
        didSet { defaults.set(size.rawValue, forKey: Keys.size) }
    }

    var theme: ReaderTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var menuBarIcon: MenuBarIcon {
        didSet { defaults.set(menuBarIcon.rawValue, forKey: Keys.menuBarIcon) }
    }

    var accent: ReaderAccent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    /// The colour used when `accent` is `.custom`; kept when another accent is chosen.
    var customAccent: AccentRGB {
        didSet { defaults.set(customAccent.hex, forKey: Keys.customAccent) }
    }

    var viewMode: ReaderViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Keys.viewMode) }
    }

    var skipUnit: SkipUnit {
        didSet { defaults.set(skipUnit.rawValue, forKey: Keys.skipUnit) }
    }

    /// How many times the Loop button repeats: 2, 3, 5, or 10, or 0 for no limit.
    var repeatCount: Int {
        didSet { defaults.set(repeatCount, forKey: Keys.repeatCount) }
    }

    var loopMode: LoopMode {
        didSet { defaults.set(loopMode.rawValue, forKey: Keys.loopMode) }
    }

    /// The ayahs a range loop repeats.
    var loopRange: ClosedRange<AyahKey>? {
        didSet { defaults.set(loopRange?.stored, forKey: Keys.loopRange) }
    }

    /// "Loop from Here" was chosen; "Loop to Here" on another ayah completes the range. Not saved.
    var loopRangeStart: AyahKey?

    var playbackStop: PlaybackStop {
        didSet { defaults.set(playbackStop.rawValue, forKey: Keys.playbackStop) }
    }

    /// Space for recordings saved while playing, in bytes; downloads are not counted.
    var cacheBudget: Int {
        didSet { defaults.set(cacheBudget, forKey: Keys.cacheBudget) }
    }

    static let cacheBudgets = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]

    /// Settings shown in place of the reader. Not saved: the reader always opens on the mushaf.
    var isShowingSettings = false
    var settingsTab = SettingsTab.appearance
    /// "Manage downloads", shown within Settings › Player.
    var showsDownloads = false
    /// The outcome of the last backup import or export, shown in Settings › General.
    var backupMessage: String?
    /// The measured height of each Settings tab's content; the reader resizes to fit it.
    var settingsContentHeights: [SettingsTab: Double] = [:]

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

    /// The mp3quran.net reading ID of the chosen reciter.
    var reciterID: Int {
        didSet { defaults.set(reciterID, forKey: Keys.reciter) }
    }

    /// Playback rate: 0.5, 0.75, 1, 1.25, 1.5, 1.75, or 2.
    var speed: Double {
        didSet { defaults.set(speed, forKey: Keys.speed) }
    }

    /// Seconds of silence between repeats of an ayah or range, 0–5.
    var repeatPause: Double {
        didSet { defaults.set(repeatPause, forKey: Keys.repeatPause) }
    }

    /// Where recitation last was, restored paused after relaunch.
    var lastPlayedAyah: AyahKey? {
        didSet { defaults.set(lastPlayedAyah?.description, forKey: Keys.lastPlayed) }
    }

    /// The Loop button's repeat counts; 0 repeats without limit.
    static let repeatCounts = [2, 3, 5, 10, 0]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = defaults.string(forKey: Keys.size).flatMap(ReaderSize.init(rawValue:)) ?? .medium
        theme = defaults.string(forKey: Keys.theme).flatMap(ReaderTheme.init(rawValue:)) ?? .system
        menuBarIcon = defaults.string(forKey: Keys.menuBarIcon).flatMap(MenuBarIcon.init(rawValue:)) ?? .surabar
        accent = defaults.string(forKey: Keys.accent).flatMap(ReaderAccent.init(rawValue:)) ?? .system
        customAccent = defaults.string(forKey: Keys.customAccent).flatMap(AccentRGB.init(hex:)) ?? .default
        viewMode = defaults.string(forKey: Keys.viewMode).flatMap(ReaderViewMode.init(rawValue:)) ?? .quranAndPlayer
        skipUnit = defaults.string(forKey: Keys.skipUnit).flatMap(SkipUnit.init(rawValue:)) ?? .surah
        let storedCount = defaults.object(forKey: Keys.repeatCount) as? Int ?? 0
        repeatCount = Self.repeatCounts.contains(storedCount) ? storedCount : 0
        let storedRange = defaults.string(forKey: Keys.loopRange).flatMap(ClosedRange<AyahKey>.init(stored:))
        let storedLoop = defaults.string(forKey: Keys.loopMode).flatMap(LoopMode.init(rawValue:)) ?? .off
        loopMode = storedLoop == .range && storedRange == nil ? .off : storedLoop
        loopRange = storedRange
        playbackStop = defaults.string(forKey: Keys.playbackStop).flatMap(PlaybackStop.init(rawValue:)) ?? .surah
        let storedBudget = defaults.integer(forKey: Keys.cacheBudget)
        cacheBudget = Self.cacheBudgets.contains(storedBudget) ? storedBudget : 1_000_000_000
        keepOnTop = defaults.object(forKey: Keys.keepOnTop) as? Bool ?? true
        isDetached = defaults.bool(forKey: Keys.detached)
        showTranslation = defaults.object(forKey: Keys.translation) as? Bool ?? true
        script = defaults.string(forKey: Keys.script) ?? "uthmani"
        pages = defaults.dictionary(forKey: Keys.pages) as? [String: Int] ?? [:]
        selectedAyah = defaults.string(forKey: Keys.selection).flatMap(AyahKey.init(string:)) ?? AyahKey(surah: 1, ayah: 1)
        reciterID = defaults.object(forKey: Keys.reciter) as? Int ?? 123
        let storedSpeed = defaults.double(forKey: Keys.speed)
        speed = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].contains(storedSpeed) ? storedSpeed : 1
        repeatPause = min(max(defaults.double(forKey: Keys.repeatPause), 0), 5)
        lastPlayedAyah = defaults.string(forKey: Keys.lastPlayed).flatMap(AyahKey.init(string:))
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

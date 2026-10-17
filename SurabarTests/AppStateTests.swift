import AppKit
import Foundation
import MushafRendering
import Testing
@testable import Surabar

@MainActor
struct AppStateTests {
    private func temporaryDefaults() -> UserDefaults {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchThePlan() {
        let state = AppState(defaults: temporaryDefaults())
        #expect(state.size == .medium)
        #expect(state.theme == .system)
        #expect(state.keepOnTop)
        #expect(!state.isDetached)
        #expect(state.showTranslation)
        #expect(state.script == "uthmani")
        #expect(state.selectedAyah == AyahKey(surah: 1, ayah: 1))
        #expect(state.pages.isEmpty)
        #expect(state.accent == .system)
        #expect(state.menuBarIcon == .surabar)
        #expect(state.playbackStop == .surah)
        #expect(state.cacheBudget == 1_000_000_000)
        #expect(state.viewMode == .quranAndPlayer)
        #expect(state.skipUnit == .surah)
        #expect(state.repeatCount == 0)
        #expect(!state.isShowingSettings)
    }

    @Test func preferencesSurviveRelaunch() {
        let defaults = temporaryDefaults()
        let first = AppState(defaults: defaults)
        first.size = .large
        first.theme = .sepia
        first.keepOnTop = false
        first.isDetached = true
        first.showTranslation = false
        first.script = "indopak"
        first.pages = ["uthmani": 50, "indopak": 52]
        first.selectedAyah = AyahKey(surah: 2, ayah: 255)
        first.accent = .custom
        first.customAccent = AccentRGB(hex: "#2E8B7A")!
        first.viewMode = .playerOnly
        first.skipUnit = .page
        first.repeatCount = 5
        first.loopMode = .ayah
        first.menuBarIcon = .moon
        first.playbackStop = .juz
        first.cacheBudget = 2_000_000_000
        first.isShowingSettings = true

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.size == .large)
        #expect(relaunched.theme == .sepia)
        #expect(!relaunched.keepOnTop)
        #expect(relaunched.isDetached)
        #expect(!relaunched.showTranslation)
        #expect(relaunched.script == "indopak")
        #expect(relaunched.pages == ["uthmani": 50, "indopak": 52])
        #expect(relaunched.selectedAyah == AyahKey(surah: 2, ayah: 255))
        #expect(relaunched.accent == .custom)
        #expect(relaunched.customAccent.hex == "#2E8B7A")
        #expect(relaunched.viewMode == .playerOnly)
        #expect(relaunched.skipUnit == .page)
        #expect(relaunched.repeatCount == 5)
        #expect(relaunched.loopMode == .ayah)
        #expect(relaunched.menuBarIcon == .moon)
        #expect(relaunched.playbackStop == .juz)
        #expect(relaunched.cacheBudget == 2_000_000_000)
        // The reader always reopens on the mushaf.
        #expect(!relaunched.isShowingSettings)
    }

    @Test func unknownStoredValuesFallBackToDefaults() {
        let defaults = temporaryDefaults()
        defaults.set("XL", forKey: "readerSize")
        defaults.set("neon", forKey: "readerTheme")
        defaults.set("teal", forKey: "accentColor")
        defaults.set("#12345", forKey: "customAccentColor")
        defaults.set("both", forKey: "viewMode")
        defaults.set(4, forKey: "loopRepeatCount")
        let state = AppState(defaults: defaults)
        #expect(state.size == .medium)
        #expect(state.theme == .system)
        #expect(state.accent == .system)
        #expect(state.customAccent == .default)
        #expect(state.viewMode == .quranAndPlayer)
        #expect(state.repeatCount == 0)
    }

    @Test func everyMenuBarIconLoadsAsATemplate() {
        for icon in MenuBarIcon.allCases {
            let image = icon.image
            #expect(image != nil, "\(icon)")
            #expect(image?.isTemplate == true)
            #expect((image?.size.height ?? 0) <= 18, "\(icon) fits the menu bar")
        }
        #expect(MenuBarIcon.surabar.image?.size == NSSize(width: 19, height: 16), "drawn from the asset, not the fallback")
        #expect(MenuBarIcon.tile.image?.size == NSSize(width: 16, height: 16))
    }

    @Test func customAccentHexRoundTrips() {
        #expect(AccentRGB(hex: "#FF8000")?.hex == "#FF8000")
        #expect(AccentRGB(hex: "00ff00")?.hex == "#00FF00")
        #expect(AccentRGB(hex: "#GG0000") == nil)
        #expect(AccentRGB(red: 2, green: -1, blue: 0.5).hex == "#FF0080")
    }

    @Test func sepiaKeepsItsAccentOnlyWhenFollowingTheSystem() {
        #expect(ReaderPalette(theme: .sepia).accentColor == ReaderPalette.sepiaAccent)
        #expect(ReaderPalette(theme: .light).accentColor == .controlAccentColor)
        #expect(ReaderPalette(theme: .sepia, accent: .green).accentColor == .systemGreen)
    }
}

struct ReaderLayoutTests {
    @Test func popoverUsesPlannedWidths() {
        for (size, width) in [(ReaderSize.small, 340.0), (.medium, 440.0), (.large, 560.0)] {
            let popover = ReaderLayout.popoverSize(width: size.width, pageHeight: 500, showTranslation: true, availableHeight: 2000)
            #expect(Double(popover.width) == width)
        }
    }

    @Test func popoverHeightFitsThePageAndIsClampedToTheScreen() {
        let tall = ReaderLayout.popoverSize(width: 560, pageHeight: 700.4, showTranslation: true, availableHeight: 2000)
        #expect(Double(tall.height) == ReaderLayout.chromeHeight(showTranslation: true) + 701)
        let short = ReaderLayout.popoverSize(width: 560, pageHeight: 700, showTranslation: true, availableHeight: 700)
        #expect(Double(short.height) == 700 - ReaderLayout.screenMargin)
        let tiny = ReaderLayout.popoverSize(width: 340, pageHeight: 400, showTranslation: false, availableHeight: 200)
        #expect(Double(tiny.height) == ReaderLayout.minimumHeight)
    }

    @Test func playerOnlyIsCompact() {
        let compact = ReaderLayout.popoverSize(width: 440, pageHeight: 700, showTranslation: true, availableHeight: 2000,
                                               mode: .playerOnly)
        #expect(Double(compact.height) == ReaderLayout.playerOnlyHeight)
    }

    @Test func settingsFitTheirContentInEitherMode() {
        let expected = ReaderLayout.settingsHeight(content: 300.2)
        #expect(expected == ReaderLayout.headerHeight + ReaderLayout.settingsTabsHeight + 1 + 301)
        for mode in ReaderViewMode.allCases {
            // Shorter than the mushaf reader, taller than "Player only".
            let settings = ReaderLayout.popoverSize(width: 440, pageHeight: 700, showTranslation: true, availableHeight: 2000,
                                                    mode: mode, settingsContentHeight: 300.2)
            #expect(Double(settings.height) == expected)
        }
        let clamped = ReaderLayout.popoverSize(width: 440, pageHeight: 700, showTranslation: true, availableHeight: 300,
                                               mode: .playerOnly, settingsContentHeight: 600)
        #expect(Double(clamped.height) == 300 - ReaderLayout.screenMargin)
    }

    @Test func translationStripAddsHeight() {
        let with = ReaderLayout.preferredHeight(pageHeight: 500, showTranslation: true)
        let without = ReaderLayout.preferredHeight(pageHeight: 500, showTranslation: false)
        #expect(with - without == ReaderLayout.translationHeight)
    }
}

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

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.size == .large)
        #expect(relaunched.theme == .sepia)
        #expect(!relaunched.keepOnTop)
        #expect(relaunched.isDetached)
        #expect(!relaunched.showTranslation)
        #expect(relaunched.script == "indopak")
        #expect(relaunched.pages == ["uthmani": 50, "indopak": 52])
        #expect(relaunched.selectedAyah == AyahKey(surah: 2, ayah: 255))
    }

    @Test func unknownStoredValuesFallBackToDefaults() {
        let defaults = temporaryDefaults()
        defaults.set("XL", forKey: "readerSize")
        defaults.set("neon", forKey: "readerTheme")
        let state = AppState(defaults: defaults)
        #expect(state.size == .medium)
        #expect(state.theme == .system)
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

    @Test func translationStripAddsHeight() {
        let with = ReaderLayout.preferredHeight(pageHeight: 500, showTranslation: true)
        let without = ReaderLayout.preferredHeight(pageHeight: 500, showTranslation: false)
        #expect(with - without == ReaderLayout.translationHeight)
    }
}

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
    }

    @Test func preferencesSurviveRelaunch() {
        let defaults = temporaryDefaults()
        let first = AppState(defaults: defaults)
        first.size = .large
        first.theme = .sepia
        first.keepOnTop = false
        first.isDetached = true
        first.showTranslation = false

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.size == .large)
        #expect(relaunched.theme == .sepia)
        #expect(!relaunched.keepOnTop)
        #expect(relaunched.isDetached)
        #expect(!relaunched.showTranslation)
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
            #expect(Double(ReaderLayout.popoverSize(width: size.width, showTranslation: true, availableHeight: 2000).width) == width)
        }
    }

    @Test func popoverHeightIsClampedToTheScreen() {
        let tall = ReaderLayout.popoverSize(width: 560, showTranslation: true, availableHeight: 2000)
        #expect(Double(tall.height) == ReaderLayout.preferredHeight(width: 560, showTranslation: true))
        let short = ReaderLayout.popoverSize(width: 560, showTranslation: true, availableHeight: 700)
        #expect(Double(short.height) == 700 - ReaderLayout.screenMargin)
        let tiny = ReaderLayout.popoverSize(width: 340, showTranslation: false, availableHeight: 200)
        #expect(Double(tiny.height) == ReaderLayout.minimumHeight)
    }

    @Test func translationStripAddsHeight() {
        let with = ReaderLayout.preferredHeight(width: 440, showTranslation: true)
        let without = ReaderLayout.preferredHeight(width: 440, showTranslation: false)
        #expect(with - without == ReaderLayout.translationHeight)
    }
}

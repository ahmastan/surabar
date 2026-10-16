import AppKit
import Foundation
import MushafRendering
import QuranStore
import Testing
@testable import Surabar

/// These use the real bundled Quran data, which is generated locally and not available on CI.
private let library = try? QuranLibrary.loadBundled().get()

@MainActor
@Suite(.enabled(if: library != nil, "Run tools/prepare_app_resources.py to bundle the Quran data"))
struct ReaderModelTests {
    private func makeModel() -> ReaderModel {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ReaderModel(state: AppState(defaults: defaults), library: .success(library!))
    }

    @Test func startsAtTheFirstPageWithTheFirstAyahSelected() {
        let model = makeModel()
        #expect(model.state.script == "uthmani")
        #expect(model.pageNumber == 1)
        #expect(model.state.selectedAyah == AyahKey(surah: 1, ayah: 1))
        #expect(model.currentSurah?.nameSimple == "Al-Fatihah")
    }

    @Test func navigationResolvesAyahsPagesSurahsAndJuz() {
        let model = makeModel()
        model.goTo(AyahKey(surah: 2, ayah: 255))
        #expect(model.pageNumber == 42)
        #expect(model.isOnPage(AyahKey(surah: 2, ayah: 255)))
        model.jump(to: .page(604))
        #expect(model.pageNumber == 604)
        #expect(model.state.selectedAyah == AyahKey(surah: 112, ayah: 1))
        model.goTo(surah: 36)
        #expect(model.state.selectedAyah == AyahKey(surah: 36, ayah: 1))
        model.goTo(juz: 30)
        #expect(model.state.selectedAyah == AyahKey(surah: 78, ayah: 1))
        #expect(model.pageInfo?.juz == 30)
        model.goTo(AyahKey(surah: 2, ayah: 999))
        #expect(model.state.selectedAyah == AyahKey(surah: 78, ayah: 1), "invalid ayahs are ignored")
    }

    @Test func switchingScriptKeepsTheSelectedAyahInView() {
        let model = makeModel()
        for ayah in [AyahKey(surah: 2, ayah: 255), AyahKey(surah: 18, ayah: 10), AyahKey(surah: 114, ayah: 6)] {
            model.goTo(ayah)
            model.switchScript(to: "indopak")
            #expect(model.state.script == "indopak")
            #expect(model.isOnPage(ayah))
            #expect(model.state.selectedAyah == ayah)
            model.switchScript(to: "uthmani")
            #expect(model.isOnPage(ayah))
        }
    }

    @Test func pageTurnsKeepTheSelectionOnScreen() {
        let model = makeModel()
        model.goTo(AyahKey(surah: 2, ayah: 255))
        model.turnPage(1)
        #expect(model.pageNumber == 43)
        #expect(model.isOnPage(model.state.selectedAyah))
        model.goToPage(1)
        model.turnPage(-1)
        #expect(model.pageNumber == 1)
    }

    @Test func adjacentAyahSelectionCrossesPages() {
        let model = makeModel()
        model.goTo(AyahKey(surah: 1, ayah: 7))
        model.selectAdjacentAyah(1)
        #expect(model.state.selectedAyah == AyahKey(surah: 2, ayah: 1))
        #expect(model.pageNumber == 2)
        model.selectAdjacentAyah(-1)
        #expect(model.state.selectedAyah == AyahKey(surah: 1, ayah: 7))
        #expect(model.pageNumber == 1)
    }

    @Test func copyingPreservesTheSourceText() throws {
        let model = makeModel()
        let ayah = AyahKey(surah: 112, ayah: 1)
        let layout = try #require(model.layout)
        let source = try library!.store.text(of: ayah, in: layout)
        model.copy(ayah, withTranslation: false)
        let copied = try #require(NSPasteboard.general.string(forType: .string))
        #expect(copied == "\(source)\n(Quran 112:1)")
        #expect(source.unicodeScalars.count > 10)
        model.copy(ayah, withTranslation: true)
        #expect(NSPasteboard.general.string(forType: .string)?.contains("Say, \"He is Allāh, [who is] One,") == true)
    }

    @Test func everyPageLaysOutWithoutDefectsAtTheReaderWidths() throws {
        let model = makeModel()
        for script in ["uthmani", "indopak"] {
            model.switchScript(to: script)
            let layout = try #require(model.layout)
            for page in [1, 2, 50, layout.pageCount] {
                model.goToPage(page)
                for size in ReaderSize.allCases {
                    let height = model.pageHeight(width: size.width)
                    let result = try #require(model.pageLayout(fitting: CGSize(width: size.width, height: height)))
                    #expect(!result.diagnostics.hasDefects, "\(script) page \(page) at \(size)")
                    #expect(abs(Double(result.size.width) - size.width) < 1)
                }
            }
        }
    }
}

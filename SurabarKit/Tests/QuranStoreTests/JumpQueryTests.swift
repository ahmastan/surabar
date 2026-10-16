import MushafRendering
import QuranStore
import Testing

private let names = ["Al-Fatihah", "Al-Baqarah", "Ali 'Imran", "An-Nisa", "Al-Ma'idah"]
private let counts = [7, 286, 200, 176, 120]
private let surahs = zip(names, counts).enumerated().map { index, entry in
    Surah(number: index + 1, nameSimple: entry.0, nameComplex: entry.0, nameArabic: "", revelationPlace: "", ayahCount: entry.1)
}

private func targets(_ input: String, currentSurah: Int = 2) -> [JumpTarget] {
    JumpQuery.suggestions(for: input, currentSurah: currentSurah, surahs: surahs, pageCount: 604).map(\.target)
}

@Test func parsesAyahReferences() {
    #expect(targets("2:255") == [.ayah(AyahKey(surah: 2, ayah: 255))])
    #expect(targets(" 2.255 ") == [.ayah(AyahKey(surah: 2, ayah: 255))])
    #expect(targets("2 255") == [.ayah(AyahKey(surah: 2, ayah: 255))])
    #expect(targets("2:287").isEmpty)
    #expect(targets("9:1").isEmpty)
}

@Test func parsesPagesWithinRange() {
    #expect(targets("p 50") == [.page(50)])
    #expect(targets("P50") == [.page(50)])
    #expect(targets("page 604") == [.page(604)])
    #expect(targets("p 605").isEmpty)
}

@Test func bareNumberIsAnAyahInTheCurrentSurahThenASurah() {
    #expect(targets("5") == [.ayah(AyahKey(surah: 2, ayah: 5)), .surah(5)])
    #expect(targets("150", currentSurah: 1).isEmpty)
    #expect(targets("150", currentSurah: 2) == [.ayah(AyahKey(surah: 2, ayah: 150))])
}

@Test func matchesSurahNamesLoosely() {
    #expect(targets("baq") == [.surah(2)])
    #expect(targets("al baqara") == [.surah(2)])
    #expect(targets("FATIHA") == [.surah(1)])
    #expect(targets("imran") == [.surah(3)])
    // Names whose part starts with the query come first.
    #expect(targets("al").prefix(2) == [.surah(1), .surah(2)])
    #expect(targets("").isEmpty)
    #expect(targets("x").isEmpty)
}

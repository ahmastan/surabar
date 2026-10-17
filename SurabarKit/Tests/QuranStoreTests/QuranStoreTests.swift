import Foundation
import GRDB
import MushafRendering
import QuranStore
import Testing

/// A synthetic database with the generated schema: 114 surahs of two ayahs, one page per surah.
/// Text is ordinary Arabic, not Quranic.
private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-store-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE surahs (number INTEGER PRIMARY KEY, name_arabic TEXT, name_simple TEXT, name_complex TEXT,
                                 revelation_place TEXT, ayah_count INTEGER, bismillah_pre INTEGER);
            CREATE TABLE ayahs (surah INTEGER, ayah INTEGER, juz INTEGER, hizb INTEGER, rub INTEGER);
            CREATE TABLE layouts (id TEXT, name TEXT, page_count INTEGER, lines_per_page INTEGER, verified INTEGER,
                                  font_file TEXT, font_sha256 TEXT, font_calibration REAL, page_font_url TEXT,
                                  page_font_calibration REAL, page_font_line_height REAL, page_font_ascent REAL);
            CREATE TABLE words (layout TEXT, word INTEGER, surah INTEGER, ayah INTEGER, position INTEGER, text TEXT,
                                glyph TEXT);
            CREATE TABLE page_fonts (layout TEXT, page INTEGER, file TEXT, bytes INTEGER, sha256 TEXT);
            CREATE TABLE lines (layout TEXT, page INTEGER, line INTEGER, type TEXT, centered INTEGER,
                                first_word INTEGER, last_word INTEGER, surah INTEGER);
            CREATE TABLE ayah_pages (layout TEXT, surah INTEGER, ayah INTEGER, page INTEGER);
            INSERT INTO layouts VALUES ('test', 'Test layout', 114, 15, 1, 'font.ttf', '', 0.05,
                                        'https://example.invalid/p{page}.woff2', 0.06, 1.8, 1.2);
            INSERT INTO page_fonts VALUES ('test', 2, 'p2.woff2', 20, 'b'), ('test', 1, 'p1.woff2', 10, 'a');
            """)
        var word = 0
        for surah in 1 ... 114 {
            try db.execute(sql: "INSERT INTO surahs VALUES (?, ?, ?, ?, 'makkah', 2, ?)",
                           arguments: [surah, "اسم\(surah)", "Name-\(surah)", "Name \(surah)", surah != 1 && surah != 9])
            var line = 1
            try db.execute(sql: "INSERT INTO lines VALUES ('test', ?, ?, 'surah_name', 1, NULL, NULL, ?)", arguments: [surah, line, surah])
            if surah != 1 && surah != 9 {
                line += 1
                try db.execute(sql: "INSERT INTO lines VALUES ('test', ?, ?, 'basmallah', 1, NULL, NULL, NULL)", arguments: [surah, line])
            }
            let first = word + 1
            for ayah in 1 ... 2 {
                try db.execute(sql: "INSERT INTO ayahs VALUES (?, ?, ?, 1, 1)", arguments: [surah, ayah, surah <= 57 ? 1 : 2])
                try db.execute(sql: "INSERT INTO ayah_pages VALUES ('test', ?, ?, ?)", arguments: [surah, ayah, surah])
                for (position, text) in ["كلمة", "نص", "\(ayah)"].enumerated() {
                    word += 1
                    try db.execute(sql: "INSERT INTO words VALUES ('test', ?, ?, ?, ?, ?, ?)",
                                   arguments: [word, surah, ayah, position + 1, text, String(UnicodeScalar(0xFC41 + position)!)])
                }
            }
            line += 1
            try db.execute(sql: "INSERT INTO lines VALUES ('test', ?, ?, 'ayah', 0, ?, ?, NULL)", arguments: [surah, line, first, word])
        }
    }
    return url
}

@Test func loadsMetadataAndPages() throws {
    let url = try makeFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try QuranStore(url: url)
    #expect(store.surahs.count == 114)
    let layout = try store.layout("test")
    #expect(layout.calibration == 0.05)
    #expect(layout.pageFonts == PageFontSettings(urlTemplate: "https://example.invalid/p{page}.woff2", calibration: 0.06,
                                                 lineHeight: 1.8, ascent: 1.2))
    #expect(layout.pageFonts?.url(page: 12)?.absoluteString == "https://example.invalid/p12.woff2")
    #expect(try store.pageFontFiles(of: layout).map(\.file) == ["p1.woff2", "p2.woff2"])

    let page = try store.page(2, of: layout)
    #expect(page.lines.map(\.kind) == [.surahName, .basmallah, .ayah])
    #expect(page.lines[0].items.map(\.text) == ["سورة اسم2"])
    // The basmallah line uses 1:1's words without its ayah-number word.
    #expect(page.lines[1].items.map(\.text) == ["كلمة", "نص"])
    #expect(page.lines[1].items.map(\.glyphs) == ["\u{FC41}", "\u{FC42}"])
    #expect(page.lines[2].items[0].glyphs == "\u{FC41}")
    #expect(page.lines[2].items.count == 6)
    #expect(page.lines[2].items[3].ayah == AyahKey(surah: 2, ayah: 2))
    #expect(try store.page(1, of: layout).lines.map(\.kind) == [.surahName, .ayah])
}

@Test func answersNavigationQueries() throws {
    let url = try makeFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try QuranStore(url: url)
    let layout = try store.layout("test")

    let info = try store.pageInfo(58, of: layout)
    #expect(info.firstAyah == AyahKey(surah: 58, ayah: 1))
    #expect(info.lastAyah == AyahKey(surah: 58, ayah: 2))
    #expect(info.surahs == [58])
    #expect(info.juz == 2)
    #expect(try store.firstPage(of: AyahKey(surah: 7, ayah: 2), in: layout) == 7)
    #expect(try store.firstAyah(ofJuz: 2) == AyahKey(surah: 58, ayah: 1))
    #expect(try store.text(of: AyahKey(surah: 3, ayah: 1), in: layout) == "كلمة نص 1")
    #expect(store.ayah(after: AyahKey(surah: 1, ayah: 2)) == AyahKey(surah: 2, ayah: 1))
    #expect(store.ayah(before: AyahKey(surah: 2, ayah: 1)) == AyahKey(surah: 1, ayah: 2))
    #expect(store.ayah(after: AyahKey(surah: 114, ayah: 2)) == nil)
    #expect(store.contains(AyahKey(surah: 114, ayah: 2)))
    #expect(!store.contains(AyahKey(surah: 114, ayah: 3)))
    #expect(throws: QuranStoreError.self) { try store.page(115, of: layout) }
}

@Test func missingDatabaseIsReported() {
    #expect(throws: QuranStoreError.self) {
        try QuranStore(url: URL(fileURLWithPath: "/nonexistent/quran.sqlite"))
    }
}

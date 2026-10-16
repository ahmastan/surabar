import Foundation
import GRDB
import MushafRendering

public struct QuranStoreError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct LayoutInfo: Sendable, Hashable {
    public let id: String
    public let name: String
    public let pageCount: Int
    public let linesPerPage: Int
    public let verified: Bool
    public let fontFile: String
    public let calibration: Double?
}

public struct Surah: Sendable, Hashable, Identifiable {
    public let number: Int
    public let nameSimple: String
    public let nameComplex: String
    public let nameArabic: String
    public let revelationPlace: String
    public let ayahCount: Int

    public var id: Int { number }

    public init(number: Int, nameSimple: String, nameComplex: String, nameArabic: String, revelationPlace: String, ayahCount: Int) {
        self.number = number
        self.nameSimple = nameSimple
        self.nameComplex = nameComplex
        self.nameArabic = nameArabic
        self.revelationPlace = revelationPlace
        self.ayahCount = ayahCount
    }
}

/// Where a page sits in the Quran: its ayahs and the divisions it starts in.
public struct PageInfo: Sendable, Hashable {
    public let number: Int
    public let firstAyah: AyahKey
    public let lastAyah: AyahKey
    public let juz: Int
    public let hizb: Int
    /// Surahs with at least one ayah on the page, in order.
    public let surahs: [Int]
}

/// Read-only access to the database produced by tools/build_quran_db.py.
public final class QuranStore: Sendable {
    private let queue: DatabaseQueue
    public let surahs: [Surah]
    public let layouts: [LayoutInfo]
    private let basmallahs: [String: [LineItem]]

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
            (surahs, layouts, basmallahs) = try queue.read { db in
                let surahs = try Row.fetchAll(db, sql: """
                    SELECT number, name_simple, name_complex, name_arabic, revelation_place, ayah_count
                    FROM surahs ORDER BY number
                    """).map { row in
                    Surah(number: row[0], nameSimple: row[1], nameComplex: row[2], nameArabic: row[3],
                          revelationPlace: row[4], ayahCount: row[5])
                }
                let layouts = try Row.fetchAll(db, sql: """
                    SELECT id, name, page_count, lines_per_page, verified, font_file, font_calibration
                    FROM layouts ORDER BY id
                    """).map { row in
                    LayoutInfo(id: row[0], name: row[1], pageCount: row[2], linesPerPage: row[3],
                               verified: row[4], fontFile: row[5], calibration: row[6])
                }
                var basmallahs: [String: [LineItem]] = [:]
                for layout in layouts {
                    // The source words of 1:1 in this layout, excluding its ayah-number word. Text is not modified.
                    basmallahs[layout.id] = try String.fetchAll(db, sql: """
                        SELECT text FROM words WHERE layout = ? AND surah = 1 AND ayah = 1 ORDER BY word
                        """, arguments: [layout.id])
                        .filter(Self.containsArabicLetter)
                        .map { LineItem(text: $0) }
                }
                return (surahs, layouts, basmallahs)
            }
        } catch let error as DatabaseError {
            throw QuranStoreError("Cannot read \(url.lastPathComponent): \(error.message ?? error.description)")
        }
        guard surahs.count == 114 else { throw QuranStoreError("Expected 114 surahs, found \(surahs.count)") }
    }

    public func layout(_ id: String) throws -> LayoutInfo {
        guard let info = layouts.first(where: { $0.id == id }) else {
            throw QuranStoreError("Layout \(id) is not in the database")
        }
        return info
    }

    public func surah(_ number: Int) -> Surah? {
        surahs.indices.contains(number - 1) ? surahs[number - 1] : nil
    }

    public func contains(_ ayah: AyahKey) -> Bool {
        guard let surah = surah(ayah.surah) else { return false }
        return (1 ... surah.ayahCount).contains(ayah.ayah)
    }

    // MARK: Pages

    public func page(_ number: Int, of layout: LayoutInfo) throws -> MushafPage {
        let surahTitles = Dictionary(uniqueKeysWithValues: surahs.map { ($0.number, "سورة \($0.nameArabic)") })
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT line, type, centered, first_word, last_word, surah FROM lines
                WHERE layout = ? AND page = ? ORDER BY line
                """, arguments: [layout.id, number])
            guard !rows.isEmpty else { throw QuranStoreError("Page \(number) is not in layout \(layout.id)") }
            let words = try Row.fetchAll(db, sql: """
                SELECT w.word, w.surah, w.ayah, w.text FROM words w
                JOIN lines l ON l.layout = w.layout AND w.word BETWEEN l.first_word AND l.last_word
                WHERE l.layout = ? AND l.page = ? ORDER BY w.word
                """, arguments: [layout.id, number])
            var byWord: [Int: LineItem] = [:]
            for row in words {
                byWord[row[0]] = LineItem(text: row[3], wordID: row[0], ayah: AyahKey(surah: row[1], ayah: row[2]))
            }
            return MushafPage(number: number, linesPerPage: layout.linesPerPage, lines: try rows.map { row in
                let type: String = row[1]
                guard let kind = LineKind(rawValue: type) else {
                    throw QuranStoreError("Unknown line type \(type) on page \(number)")
                }
                let items: [LineItem]
                switch kind {
                case .ayah:
                    let first: Int = row[3], last: Int = row[4]
                    items = (first ... last).compactMap { byWord[$0] }
                case .surahName:
                    items = [LineItem(text: surahTitles[row[5] ?? 0] ?? "")]
                case .basmallah:
                    items = basmallahs[layout.id] ?? []
                }
                return MushafLine(number: row[0], kind: kind, isCentered: row[2], items: items)
            })
        }
    }

    public func pageInfo(_ number: Int, of layout: LayoutInfo) throws -> PageInfo {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.surah, p.ayah, a.juz, a.hizb FROM ayah_pages p
                JOIN ayahs a ON a.surah = p.surah AND a.ayah = p.ayah
                WHERE p.layout = ? AND p.page = ? ORDER BY p.surah, p.ayah
                """, arguments: [layout.id, number])
            guard let first = rows.first, let last = rows.last else {
                throw QuranStoreError("Page \(number) is not in layout \(layout.id)")
            }
            var surahs: [Int] = []
            for row in rows where surahs.last != row[0] { surahs.append(row[0]) }
            return PageInfo(number: number, firstAyah: AyahKey(surah: first[0], ayah: first[1]),
                            lastAyah: AyahKey(surah: last[0], ayah: last[1]), juz: first[2], hizb: first[3], surahs: surahs)
        }
    }

    /// Every page showing part of an ayah, in order; the first is where it starts.
    public func pages(containing ayah: AyahKey, in layout: LayoutInfo) throws -> [Int] {
        try queue.read { db in
            try Int.fetchAll(db, sql: "SELECT page FROM ayah_pages WHERE layout = ? AND surah = ? AND ayah = ? ORDER BY page",
                             arguments: [layout.id, ayah.surah, ayah.ayah])
        }
    }

    public func firstPage(of ayah: AyahKey, in layout: LayoutInfo) throws -> Int {
        guard let page = try pages(containing: ayah, in: layout).first else {
            throw QuranStoreError("\(ayah) is not in layout \(layout.id)")
        }
        return page
    }

    /// The first ayah of a juz (1–30).
    public func firstAyah(ofJuz juz: Int) throws -> AyahKey {
        try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT surah, ayah FROM ayahs WHERE juz = ? ORDER BY surah, ayah LIMIT 1",
                                             arguments: [juz]) else {
                throw QuranStoreError("Juz \(juz) is not in the database")
            }
            return AyahKey(surah: row[0], ayah: row[1])
        }
    }

    // MARK: Ayahs

    /// The ayah's source words joined by single spaces, as the layout's word data has them.
    public func text(of ayah: AyahKey, in layout: LayoutInfo) throws -> String {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM words WHERE layout = ? AND surah = ? AND ayah = ? ORDER BY word",
                                arguments: [layout.id, ayah.surah, ayah.ayah]).joined(separator: " ")
        }
    }

    public func ayah(after ayah: AyahKey) -> AyahKey? {
        guard let surah = surah(ayah.surah) else { return nil }
        if ayah.ayah < surah.ayahCount { return AyahKey(surah: ayah.surah, ayah: ayah.ayah + 1) }
        return ayah.surah < 114 ? AyahKey(surah: ayah.surah + 1, ayah: 1) : nil
    }

    public func ayah(before ayah: AyahKey) -> AyahKey? {
        if ayah.ayah > 1 { return AyahKey(surah: ayah.surah, ayah: ayah.ayah - 1) }
        guard ayah.surah > 1, let previous = surah(ayah.surah - 1) else { return nil }
        return AyahKey(surah: previous.number, ayah: previous.ayahCount)
    }

    private static func containsArabicLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0621 ... 0x064A).contains($0.value) || (0x0671 ... 0x06D3).contains($0.value) }
    }
}

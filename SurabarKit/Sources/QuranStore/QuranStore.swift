import Foundation
import MushafRendering
import SQLite3

public struct QuranStoreError: Error, CustomStringConvertible {
    public let description: String
}

public struct LayoutInfo: Sendable {
    public let id: String
    public let name: String
    public let pageCount: Int
    public let linesPerPage: Int
    public let verified: Bool
    public let fontFile: String
    public let calibration: Double?
}

/// Read-only access to the database produced by tools/build_quran_db.py.
public final class QuranStore {
    private var handle: OpaquePointer?
    private var basmallahs: [String: [LineItem]] = [:]
    private var surahTitles: [Int: String] = [:]

    public init(url: URL) throws {
        let uri = "file:\(url.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw QuranStoreError(description: "Cannot open \(url.path): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    public func layouts() throws -> [LayoutInfo] {
        try query("SELECT id, name, page_count, lines_per_page, verified, font_file, font_calibration FROM layouts ORDER BY id") { row in
            LayoutInfo(id: row.text(0), name: row.text(1), pageCount: row.int(2), linesPerPage: row.int(3),
                       verified: row.int(4) != 0, fontFile: row.text(5), calibration: row.optionalDouble(6))
        }
    }

    public func layout(_ id: String) throws -> LayoutInfo {
        guard let info = try layouts().first(where: { $0.id == id }) else {
            throw QuranStoreError(description: "Layout \(id) is not in the database")
        }
        return info
    }

    public func page(_ number: Int, of layout: LayoutInfo) throws -> MushafPage {
        let rows = try query("SELECT line, type, centered, first_word, last_word, surah FROM lines WHERE layout = ?1 AND page = ?2 ORDER BY line",
                             bind: [.text(layout.id), .int(number)]) { row in
            (line: row.int(0), type: row.text(1), centered: row.int(2) != 0,
             first: row.optionalInt(3), last: row.optionalInt(4), surah: row.optionalInt(5))
        }
        guard !rows.isEmpty else { throw QuranStoreError(description: "Page \(number) is not in layout \(layout.id)") }
        var lines: [MushafLine] = []
        for row in rows {
            guard let kind = LineKind(rawValue: row.type) else {
                throw QuranStoreError(description: "Unknown line type \(row.type) on page \(number)")
            }
            let items: [LineItem]
            switch kind {
            case .ayah:
                items = try words(layout: layout.id, from: row.first ?? 0, through: row.last ?? -1)
            case .surahName:
                items = [LineItem(text: try surahTitle(row.surah ?? 0))]
            case .basmallah:
                items = try basmallah(layout: layout.id)
            }
            lines.append(MushafLine(number: row.line, kind: kind, isCentered: row.centered, items: items))
        }
        return MushafPage(number: number, linesPerPage: layout.linesPerPage, lines: lines)
    }

    private func words(layout: String, from first: Int, through last: Int) throws -> [LineItem] {
        try query("SELECT word, surah, ayah, text FROM words WHERE layout = ?1 AND word BETWEEN ?2 AND ?3 ORDER BY word",
                  bind: [.text(layout), .int(first), .int(last)]) { row in
            LineItem(text: row.text(3), wordID: row.int(0), ayah: AyahKey(surah: row.int(1), ayah: row.int(2)))
        }
    }

    /// Surah title from metadata; not Quranic text.
    private func surahTitle(_ surah: Int) throws -> String {
        if let title = surahTitles[surah] { return title }
        guard let name = try query("SELECT name_arabic FROM surahs WHERE number = ?1", bind: [.int(surah)], { $0.text(0) }).first else {
            throw QuranStoreError(description: "Surah \(surah) is not in the database")
        }
        surahTitles[surah] = "سورة \(name)"
        return surahTitles[surah]!
    }

    /// The source words of 1:1 in this layout, excluding its ayah-number word. The text is not modified.
    private func basmallah(layout: String) throws -> [LineItem] {
        if let cached = basmallahs[layout] { return cached }
        let words = try query("SELECT text FROM words WHERE layout = ?1 AND surah = 1 AND ayah = 1 ORDER BY word",
                              bind: [.text(layout)]) { LineItem(text: $0.text(0)) }
        let items = words.filter { word in
            word.text.unicodeScalars.contains { (0x0621 ... 0x064A).contains($0.value) || (0x0671 ... 0x06D3).contains($0.value) }
        }
        basmallahs[layout] = items
        return items
    }

    // MARK: SQLite

    enum Value { case int(Int), text(String) }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
    }

    private func query<T>(_ sql: String, bind values: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw QuranStoreError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, transient)
            }
        }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw QuranStoreError(description: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

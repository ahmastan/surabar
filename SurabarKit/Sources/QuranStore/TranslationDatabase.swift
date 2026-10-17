import Foundation
import GRDB
import MushafRendering

/// What is shown about a translation: QuranEnc.com's catalogue entry, which credits its publisher and
/// version as QuranEnc's terms require.
public struct TranslationInfo: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    /// QuranEnc's title, e.g. "English Translation - Noor International Center".
    public let title: String
    /// A shorter name where a better-known one exists, e.g. "Saheeh International".
    public let displayName: String?
    public let description: String
    /// ISO 639-1 code.
    public let language: String
    /// "ltr" or "rtl".
    public let direction: String
    public let version: String
    public let lastUpdate: Int
    public let source: String

    public var id: String { key }

    public init(key: String, title: String, displayName: String? = nil, description: String, language: String,
                direction: String, version: String, lastUpdate: Int, source: String = "QuranEnc.com") {
        self.key = key
        self.title = title
        self.displayName = displayName
        self.description = description
        self.language = language
        self.direction = direction
        self.version = version
        self.lastUpdate = lastUpdate
        self.source = source
    }

    /// The name in the translation strip: the display name, or the title without its language prefix.
    public var name: String {
        if let displayName { return displayName }
        guard let range = title.range(of: " - ") else { return title }
        return String(title[range.upperBound...])
    }

    public var isRightToLeft: Bool { direction == "rtl" }

    /// The credit QuranEnc's terms ask for: publisher, source, and version.
    public var credit: String { "\(title), \(source) version \(version)" }

    /// Whether `other` is a later version ("1.1.10" is later than "1.1.9").
    public func isOlder(than other: TranslationInfo) -> Bool {
        let mine = version.split(separator: ".").map { Int($0) ?? 0 }
        let theirs = other.version.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < theirs.count ? theirs[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case key, title, displayName = "display_name", description, language, direction, version, lastUpdate = "last_update", source
    }
}

/// A translation file from QuranEnc.com (SQLite: sura, aya, translation, footnotes), read whole and
/// shown unmodified.
public struct TranslationDatabase: Sendable {
    public let info: TranslationInfo
    private let texts: [AyahKey: String]
    private let footnoteTexts: [AyahKey: String]

    /// Reads and checks a translation file: every ayah of the Quran must be present.
    public init(url: URL, info: TranslationInfo, ayahCount: Int = 6236) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT sura, aya, translation, footnotes FROM translations")
        }
        var texts: [AyahKey: String] = [:]
        var footnotes: [AyahKey: String] = [:]
        for row in rows {
            let key = AyahKey(surah: row["sura"], ayah: row["aya"])
            texts[key] = row["translation"] ?? ""
            if let note: String = row["footnotes"], !note.isEmpty { footnotes[key] = note }
        }
        guard texts.count == ayahCount, texts.values.allSatisfy({ !$0.isEmpty }) else {
            throw QuranStoreError("\(info.title) has \(texts.count) of \(ayahCount) ayahs")
        }
        self.info = info
        self.texts = texts
        footnoteTexts = footnotes
    }

    public func text(for ayah: AyahKey) -> String? { texts[ayah] }

    /// The translator's footnotes for an ayah, one per line, as in the file.
    public func footnotes(for ayah: AyahKey) -> String? { footnoteTexts[ayah] }
}

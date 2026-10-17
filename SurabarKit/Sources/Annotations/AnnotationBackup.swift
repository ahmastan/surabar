import Foundation
import MushafRendering

/// The five highlight colours.
public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, orange
}

/// One kind of annotation per ayah: a bookmark (with an optional label), a highlight, or a note.
/// Each has an `updatedAt` time; when merging, the newer entry for an ayah wins.
public struct BookmarkEntry: Codable, Equatable, Sendable {
    public var ayah: String
    public var label: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(ayah: AyahKey, label: String = "", createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.ayah = ayah.description
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public struct HighlightEntry: Codable, Equatable, Sendable {
    public var ayah: String
    public var color: HighlightColor
    public var updatedAt: Date

    public init(ayah: AyahKey, color: HighlightColor, updatedAt: Date = Date()) {
        self.ayah = ayah.description
        self.color = color
        self.updatedAt = updatedAt
    }
}

public struct NoteEntry: Codable, Equatable, Sendable {
    public var ayah: String
    public var text: String
    public var updatedAt: Date

    public init(ayah: AyahKey, text: String, updatedAt: Date = Date()) {
        self.ayah = ayah.description
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// The exported annotations file. Versioned; dates are ISO 8601 and entries are sorted by ayah, so the
/// same annotations always export to the same bytes.
public struct AnnotationBackup: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// A note longer than this is rejected on import.
    public static let maximumNoteLength = 20_000

    public var format = "surabar-annotations"
    public var version = Self.currentVersion
    public var bookmarks: [BookmarkEntry]
    public var highlights: [HighlightEntry]
    public var notes: [NoteEntry]

    public init(bookmarks: [BookmarkEntry] = [], highlights: [HighlightEntry] = [], notes: [NoteEntry] = []) {
        self.bookmarks = bookmarks
        self.highlights = highlights
        self.notes = notes
    }

    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sorted())
    }

    /// Reads and validates a backup. `ayahCounts` (ayahs per surah) checks every reference.
    public static func decode(_ data: Data, ayahCounts: [Int]) throws -> AnnotationBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: AnnotationBackup
        do {
            backup = try decoder.decode(AnnotationBackup.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            throw ValidationError("The file isn't valid JSON")
        } catch {
            throw ValidationError("The file isn't a Surabar annotations backup")
        }
        try backup.validate(ayahCounts: ayahCounts)
        return backup
    }

    public func validate(ayahCounts: [Int]) throws {
        guard format == "surabar-annotations" else { throw ValidationError("The file isn't a Surabar annotations backup") }
        guard version >= 1 else { throw ValidationError("Unknown backup version \(version)") }
        guard version <= Self.currentVersion else {
            throw ValidationError("The backup is from a newer version of Surabar (format \(version))")
        }
        func check(_ ayah: String, _ kind: String, _ seen: inout Set<String>) throws {
            guard let key = AyahKey(string: ayah), (1 ... ayahCounts.count).contains(key.surah),
                  (1 ... ayahCounts[key.surah - 1]).contains(key.ayah) else {
                throw ValidationError("A \(kind) refers to \(ayah), which isn't an ayah")
            }
            guard seen.insert(ayah).inserted else { throw ValidationError("Two \(kind)s refer to \(ayah)") }
        }
        var seen = Set<String>()
        for entry in bookmarks { try check(entry.ayah, "bookmark", &seen) }
        seen = []
        for entry in highlights { try check(entry.ayah, "highlight", &seen) }
        seen = []
        for entry in notes {
            try check(entry.ayah, "note", &seen)
            guard entry.text.count <= Self.maximumNoteLength else { throw ValidationError("The note on \(entry.ayah) is too long") }
        }
    }

    /// Times rounded down to the second, the precision a backup stores.
    public func wholeSeconds() -> AnnotationBackup {
        func second(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        var copy = self
        copy.bookmarks = bookmarks.map { var entry = $0; entry.createdAt = second(entry.createdAt); entry.updatedAt = second(entry.updatedAt); return entry }
        copy.highlights = highlights.map { var entry = $0; entry.updatedAt = second(entry.updatedAt); return entry }
        copy.notes = notes.map { var entry = $0; entry.updatedAt = second(entry.updatedAt); return entry }
        return copy
    }

    /// Entries in reading order.
    public func sorted() -> AnnotationBackup {
        func order(_ lhs: String, _ rhs: String) -> Bool {
            (AyahKey(string: lhs) ?? AyahKey(surah: 0, ayah: 0)) < (AyahKey(string: rhs) ?? AyahKey(surah: 0, ayah: 0))
        }
        var copy = self
        copy.bookmarks.sort { order($0.ayah, $1.ayah) }
        copy.highlights.sort { order($0.ayah, $1.ayah) }
        copy.notes.sort { order($0.ayah, $1.ayah) }
        return copy
    }

    public struct MergeResult: Equatable, Sendable {
        public var merged: AnnotationBackup
        /// Imported entries that were added or replaced an older one.
        public var applied: Int
        /// Imported entries that were not newer than what is already here.
        public var skipped: Int
    }

    /// Merges `incoming` into these annotations: per ayah and kind, the newer entry wins; on a tie the
    /// existing entry stays. Nothing is deleted.
    public func merging(_ incoming: AnnotationBackup) -> MergeResult {
        var applied = 0, skipped = 0
        func merge<Entry>(_ existing: [Entry], _ new: [Entry], key: (Entry) -> String, date: (Entry) -> Date) -> [Entry] {
            var byAyah = Dictionary(existing.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
            for entry in new {
                if let current = byAyah[key(entry)], date(current) >= date(entry) {
                    skipped += 1
                } else {
                    byAyah[key(entry)] = entry
                    applied += 1
                }
            }
            return Array(byAyah.values)
        }
        let merged = AnnotationBackup(
            bookmarks: merge(bookmarks, incoming.bookmarks, key: \.ayah, date: \.updatedAt),
            highlights: merge(highlights, incoming.highlights, key: \.ayah, date: \.updatedAt),
            notes: merge(notes, incoming.notes, key: \.ayah, date: \.updatedAt))
        return MergeResult(merged: merged.sorted(), applied: applied, skipped: skipped)
    }
}

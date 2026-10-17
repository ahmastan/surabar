import Annotations
import Foundation
import MushafRendering
import Observation
import SwiftData

// Annotations are stored with SwiftData, one record per ayah and kind, keyed by "surah:ayah" so they
// apply in every script and layout.

@Model
final class BookmarkRecord {
    @Attribute(.unique) var ayah: String
    var label: String
    var createdAt: Date
    var updatedAt: Date

    init(ayah: String, label: String, createdAt: Date, updatedAt: Date) {
        self.ayah = ayah
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class HighlightRecord {
    @Attribute(.unique) var ayah: String
    var color: String
    var updatedAt: Date

    init(ayah: String, color: String, updatedAt: Date) {
        self.ayah = ayah
        self.color = color
        self.updatedAt = updatedAt
    }
}

@Model
final class NoteRecord {
    @Attribute(.unique) var ayah: String
    var text: String
    var updatedAt: Date

    init(ayah: String, text: String, updatedAt: Date) {
        self.ayah = ayah
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// Bookmarks, highlights, and notes. Reads come from in-memory copies (the page draws them on every
/// redraw); every change is saved immediately.
@MainActor
@Observable
final class AnnotationStore {
    private(set) var bookmarks: [AyahKey: BookmarkEntry] = [:]
    private(set) var highlights: [AyahKey: HighlightEntry] = [:]
    private(set) var notes: [AyahKey: NoteEntry] = [:]

    @ObservationIgnored private let context: ModelContext

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "Surabar/Annotations.store")

    /// The app's store in Application Support by default; tests pass their own file, or keep it in memory.
    init(url: URL = defaultURL, inMemory: Bool = false) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: url)
        }
        let container = try ModelContainer(for: BookmarkRecord.self, HighlightRecord.self, NoteRecord.self, configurations: configuration)
        context = ModelContext(container)
        reload()
    }

    // MARK: Changes

    /// Times are kept to the second, as backups store them, so an export restores exactly.
    private var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    func isBookmarked(_ ayah: AyahKey) -> Bool { bookmarks[ayah] != nil }

    func toggleBookmark(_ ayah: AyahKey) {
        if isBookmarked(ayah) { removeBookmark(ayah) } else { setBookmark(ayah, label: "") }
    }

    func setBookmark(_ ayah: AyahKey, label: String) {
        let now = self.now
        if let record = bookmarkRecord(ayah) {
            record.label = label
            record.updatedAt = now
        } else {
            context.insert(BookmarkRecord(ayah: ayah.description, label: label, createdAt: now, updatedAt: now))
        }
        commit()
    }

    func removeBookmark(_ ayah: AyahKey) {
        if let record = bookmarkRecord(ayah) { context.delete(record) }
        commit()
    }

    /// Sets or (with nil) removes an ayah's highlight.
    func setHighlight(_ ayah: AyahKey, _ color: HighlightColor?) {
        let record = highlightRecord(ayah)
        switch (record, color) {
        case (let record?, let color?):
            record.color = color.rawValue
            record.updatedAt = now
        case (nil, let color?):
            context.insert(HighlightRecord(ayah: ayah.description, color: color.rawValue, updatedAt: now))
        case (let record?, nil):
            context.delete(record)
        case (nil, nil):
            return
        }
        commit()
    }

    /// Saves a note; empty text removes it.
    func setNote(_ ayah: AyahKey, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = noteRecord(ayah)
        if trimmed.isEmpty {
            if let record { context.delete(record) }
        } else if let record {
            guard record.text != trimmed else { return }
            record.text = trimmed
            record.updatedAt = now
        } else {
            context.insert(NoteRecord(ayah: ayah.description, text: trimmed, updatedAt: now))
        }
        commit()
    }

    // MARK: Backup

    var backup: AnnotationBackup {
        AnnotationBackup(bookmarks: Array(bookmarks.values), highlights: Array(highlights.values), notes: Array(notes.values)).sorted()
    }

    /// Merges a validated backup: newer entries win, ties keep what is here. Returns how many entries were
    /// applied and skipped. Nothing changes if saving fails.
    func importBackup(_ incoming: AnnotationBackup) throws -> AnnotationBackup.MergeResult {
        let result = backup.merging(incoming.wholeSeconds())
        do {
            try replaceAll(with: result.merged)
        } catch {
            context.rollback()
            reload()
            throw error
        }
        return result
    }

    private func replaceAll(with backup: AnnotationBackup) throws {
        try context.delete(model: BookmarkRecord.self)
        try context.delete(model: HighlightRecord.self)
        try context.delete(model: NoteRecord.self)
        for entry in backup.bookmarks {
            context.insert(BookmarkRecord(ayah: entry.ayah, label: entry.label, createdAt: entry.createdAt, updatedAt: entry.updatedAt))
        }
        for entry in backup.highlights {
            context.insert(HighlightRecord(ayah: entry.ayah, color: entry.color.rawValue, updatedAt: entry.updatedAt))
        }
        for entry in backup.notes {
            context.insert(NoteRecord(ayah: entry.ayah, text: entry.text, updatedAt: entry.updatedAt))
        }
        try context.save()
        reload()
    }

    // MARK: Storage

    private func bookmarkRecord(_ ayah: AyahKey) -> BookmarkRecord? {
        let key = ayah.description
        return try? context.fetch(FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.ayah == key })).first
    }

    private func highlightRecord(_ ayah: AyahKey) -> HighlightRecord? {
        let key = ayah.description
        return try? context.fetch(FetchDescriptor<HighlightRecord>(predicate: #Predicate { $0.ayah == key })).first
    }

    private func noteRecord(_ ayah: AyahKey) -> NoteRecord? {
        let key = ayah.description
        return try? context.fetch(FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.ayah == key })).first
    }

    private func commit() {
        try? context.save()
        reload()
    }

    private func reload() {
        func keyed<Entry>(_ entries: [Entry], _ ayah: (Entry) -> String) -> [AyahKey: Entry] {
            Dictionary(entries.compactMap { entry in AyahKey(string: ayah(entry)).map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        }
        let bookmarkRecords = (try? context.fetch(FetchDescriptor<BookmarkRecord>())) ?? []
        bookmarks = keyed(bookmarkRecords.compactMap { record in
            AyahKey(string: record.ayah).map { BookmarkEntry(ayah: $0, label: record.label, createdAt: record.createdAt, updatedAt: record.updatedAt) }
        }, \.ayah)
        let highlightRecords = (try? context.fetch(FetchDescriptor<HighlightRecord>())) ?? []
        highlights = keyed(highlightRecords.compactMap { record in
            guard let ayah = AyahKey(string: record.ayah), let color = HighlightColor(rawValue: record.color) else { return nil }
            return HighlightEntry(ayah: ayah, color: color, updatedAt: record.updatedAt)
        }, \.ayah)
        let noteRecords = (try? context.fetch(FetchDescriptor<NoteRecord>())) ?? []
        notes = keyed(noteRecords.compactMap { record in
            AyahKey(string: record.ayah).map { NoteEntry(ayah: $0, text: record.text, updatedAt: record.updatedAt) }
        }, \.ayah)
    }
}

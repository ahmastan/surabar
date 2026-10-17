import Annotations
import Foundation
import MushafRendering
import Testing
@testable import Surabar

@MainActor
@Suite(.serialized)
struct AnnotationStoreTests {
    private let ayah = AyahKey(surah: 2, ayah: 255)

    @Test func bookmarksHighlightsAndNotesAreSavedPerAyah() throws {
        let store = try AnnotationStore(inMemory: true)
        store.toggleBookmark(ayah)
        #expect(store.isBookmarked(ayah))
        store.setBookmark(ayah, label: "Ayat al-Kursi")
        #expect(store.bookmarks[ayah]?.label == "Ayat al-Kursi")
        store.toggleBookmark(ayah)
        #expect(!store.isBookmarked(ayah))

        store.setHighlight(ayah, .yellow)
        store.setHighlight(ayah, .blue)
        #expect(store.highlights[ayah]?.color == .blue)
        #expect(store.highlights.count == 1, "one highlight per ayah")
        store.setHighlight(ayah, nil)
        #expect(store.highlights.isEmpty)

        store.setNote(ayah, "  Recite after prayer  ")
        #expect(store.notes[ayah]?.text == "Recite after prayer")
        store.setNote(ayah, "   ")
        #expect(store.notes[ayah] == nil, "an empty note removes it")
    }

    @Test func annotationsSurviveRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-annotations-\(UUID().uuidString)/A.store")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try AnnotationStore(url: url)
            store.setBookmark(ayah, label: "Kursi")
            store.setHighlight(AyahKey(surah: 1, ayah: 1), .pink)
            store.setNote(AyahKey(surah: 114, ayah: 6), "End")
        }
        let reopened = try AnnotationStore(url: url)
        #expect(reopened.bookmarks[ayah]?.label == "Kursi")
        #expect(reopened.highlights[AyahKey(surah: 1, ayah: 1)]?.color == .pink)
        #expect(reopened.notes[AyahKey(surah: 114, ayah: 6)]?.text == "End")
    }

    @Test func importMergesAndExportRoundTrips() throws {
        let store = try AnnotationStore(inMemory: true)
        store.setBookmark(ayah, label: "mine")
        store.setNote(AyahKey(surah: 1, ayah: 2), "kept")
        let old = Date(timeIntervalSince1970: 0)
        let incoming = AnnotationBackup(
            bookmarks: [BookmarkEntry(ayah: ayah, label: "older", createdAt: old), BookmarkEntry(ayah: AyahKey(surah: 36, ayah: 1))],
            highlights: [HighlightEntry(ayah: AyahKey(surah: 3, ayah: 1), color: .orange)])
        let result = try store.importBackup(incoming)
        #expect(result.applied == 2 && result.skipped == 1)
        #expect(store.bookmarks[ayah]?.label == "mine", "the newer bookmark here wins")
        #expect(store.isBookmarked(AyahKey(surah: 36, ayah: 1)))
        #expect(store.highlights[AyahKey(surah: 3, ayah: 1)]?.color == .orange)
        #expect(store.notes[AyahKey(surah: 1, ayah: 2)]?.text == "kept", "import never deletes")

        // Export, then import into an empty store: the same annotations.
        let data = try store.backup.encoded()
        let copy = try AnnotationStore(inMemory: true)
        _ = try copy.importBackup(AnnotationBackup.decode(data, ayahCounts: Array(repeating: 300, count: 114)))
        #expect(copy.backup == store.backup)
    }

    @Test func anInvalidBackupChangesNothing() throws {
        let store = try AnnotationStore(inMemory: true)
        store.setBookmark(ayah, label: "safe")
        let before = store.backup
        #expect(throws: AnnotationBackup.ValidationError.self) {
            _ = try AnnotationBackup.decode(Data(#"{"format":"surabar-annotations","version":1,"bookmarks":[{"ayah":"200:1","label":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"highlights":[],"notes":[]}"#.utf8),
                                            ayahCounts: Array(repeating: 300, count: 114))
        }
        #expect(store.backup == before)
    }
}

import Annotations
import Foundation
import MushafRendering
import Testing

private let counts = [7, 286, 200] + Array(repeating: 10, count: 111)
private func key(_ surah: Int, _ ayah: Int) -> AyahKey { AyahKey(surah: surah, ayah: ayah) }
private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func backupsRoundTripDeterministically() throws {
    let backup = AnnotationBackup(
        bookmarks: [BookmarkEntry(ayah: key(2, 255), label: "Ayat al-Kursi", createdAt: date(10)),
                    BookmarkEntry(ayah: key(1, 1), createdAt: date(5))],
        highlights: [HighlightEntry(ayah: key(3, 2), color: .green, updatedAt: date(20))],
        notes: [NoteEntry(ayah: key(2, 255), text: "Memorise\\nwith tafsir", updatedAt: date(30))])
    let data = try backup.encoded()
    let decoded = try AnnotationBackup.decode(data, ayahCounts: counts)
    #expect(decoded == backup.sorted())
    #expect(decoded.bookmarks.map(\.ayah) == ["1:1", "2:255"], "entries are in reading order")
    #expect(try decoded.encoded() == data, "the same annotations give the same bytes")
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"version\" : 1") && text.contains("1970-01-01T00:00:10Z"))
}

@Test func invalidBackupsAreRejectedWithAReason() throws {
    func reason(_ json: String) -> String? {
        do {
            _ = try AnnotationBackup.decode(Data(json.utf8), ayahCounts: counts)
            return nil
        } catch {
            return (error as? AnnotationBackup.ValidationError)?.description
        }
    }
    let empty = #""bookmarks":[],"highlights":[],"notes":[]"#
    #expect(reason("not json") == "The file isn't valid JSON")
    #expect(reason(#"{"hello":1}"#) == "The file isn't a Surabar annotations backup")
    #expect(reason(#"{"format":"other","version":1,"# + empty + "}") == "The file isn't a Surabar annotations backup")
    #expect(reason(#"{"format":"surabar-annotations","version":2,"# + empty + "}")?.contains("newer version") == true)
    #expect(reason(#"{"format":"surabar-annotations","version":1,"bookmarks":[{"ayah":"1:8","label":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"highlights":[],"notes":[]}"#)
            == "A bookmark refers to 1:8, which isn't an ayah")
    #expect(reason(#"{"format":"surabar-annotations","version":1,"bookmarks":[],"highlights":[{"ayah":"2:1","color":"purple","updatedAt":"2026-01-01T00:00:00Z"}],"notes":[]}"#)
            == "The file isn't a Surabar annotations backup")
    #expect(reason(#"{"format":"surabar-annotations","version":1,"bookmarks":[],"highlights":[],"notes":[{"ayah":"2:1","text":"a","updatedAt":"2026-01-01T00:00:00Z"},{"ayah":"2:1","text":"b","updatedAt":"2026-01-01T00:00:00Z"}]}"#)
            == "Two notes refer to 2:1")
    #expect(reason(#"{"format":"surabar-annotations","version":1,"# + empty + "}") == nil)
}

@Test func newerEntriesWinAndTiesKeepWhatIsHere() {
    let existing = AnnotationBackup(
        bookmarks: [BookmarkEntry(ayah: key(2, 255), label: "here", createdAt: date(1), updatedAt: date(50))],
        highlights: [HighlightEntry(ayah: key(1, 1), color: .yellow, updatedAt: date(50))],
        notes: [NoteEntry(ayah: key(1, 2), text: "old", updatedAt: date(10))])
    let incoming = AnnotationBackup(
        bookmarks: [BookmarkEntry(ayah: key(2, 255), label: "imported", createdAt: date(1), updatedAt: date(40)),
                    BookmarkEntry(ayah: key(3, 1), createdAt: date(5))],
        highlights: [HighlightEntry(ayah: key(1, 1), color: .blue, updatedAt: date(50))],
        notes: [NoteEntry(ayah: key(1, 2), text: "new", updatedAt: date(60))])
    let result = existing.merging(incoming)
    #expect(result.merged.bookmarks.map(\.label) == ["here", ""], "older import loses; new ayah is added")
    #expect(result.merged.highlights.first?.color == .yellow, "a tie keeps the existing entry")
    #expect(result.merged.notes.first?.text == "new")
    #expect(result.applied == 2 && result.skipped == 2)
    #expect(existing.merging(incoming).merged == result.merged, "merging is deterministic")
}

import Foundation
import MushafRendering

/// Something the jump box can go to.
public enum JumpTarget: Hashable, Sendable {
    case ayah(AyahKey)
    case page(Int)
    case surah(Int)
}

public struct JumpSuggestion: Hashable, Sendable, Identifiable {
    public let target: JumpTarget
    public let title: String
    public let detail: String

    public var id: JumpTarget { target }
}

/// Parses jump input: "2:255" (also "2.255" or "2 255"), "255" for an ayah in the current surah,
/// "p 50" or "page 50", a surah number, or part of a surah name.
public enum JumpQuery {
    public static func suggestions(for input: String, currentSurah: Int, surahs: [Surah], pageCount: Int,
                                   limit: Int = 6) -> [JumpSuggestion] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var results: [JumpSuggestion] = []
        func name(_ surah: Int) -> String { surahs[surah - 1].nameSimple }

        if let match = text.wholeMatch(of: /(\d{1,3})\s*[:.\s]\s*(\d{1,3})/) {
            let surah = Int(match.1)!, ayah = Int(match.2)!
            if (1 ... surahs.count).contains(surah), (1 ... surahs[surah - 1].ayahCount).contains(ayah) {
                results.append(JumpSuggestion(target: .ayah(AyahKey(surah: surah, ayah: ayah)), title: "\(surah):\(ayah)",
                                              detail: "\(name(surah)), ayah \(ayah)"))
            }
        } else if let match = text.wholeMatch(of: /(?i)p(?:age)?\s*(\d{1,4})/) {
            let page = Int(match.1)!
            if (1 ... pageCount).contains(page) {
                results.append(JumpSuggestion(target: .page(page), title: "Page \(page)", detail: "of \(pageCount)"))
            }
        } else if let number = Int(text) {
            if currentSurah >= 1, currentSurah <= surahs.count, (1 ... surahs[currentSurah - 1].ayahCount).contains(number) {
                results.append(JumpSuggestion(target: .ayah(AyahKey(surah: currentSurah, ayah: number)),
                                              title: "\(currentSurah):\(number)", detail: "Ayah \(number) of \(name(currentSurah))"))
            }
            if (1 ... surahs.count).contains(number) {
                results.append(JumpSuggestion(target: .surah(number), title: name(number), detail: "Surah \(number)"))
            }
        }

        let needle = normalized(text)
        if needle.count >= 2 {
            let matches = surahs.filter { surah in
                [surah.nameSimple, surah.nameComplex].contains { normalized($0).contains(needle) } || surah.nameArabic.contains(text)
            }
            // Names that start with the query rank before names that merely contain it.
            let ranked = matches.sorted { lhs, rhs in
                let left = Self.rank(lhs, needle), right = Self.rank(rhs, needle)
                return left == right ? lhs.number < rhs.number : left < right
            }
            for surah in ranked where !results.contains(where: { $0.target == .surah(surah.number) }) {
                results.append(JumpSuggestion(target: .surah(surah.number), title: surah.nameSimple, detail: "Surah \(surah.number)"))
            }
        }
        return Array(results.prefix(limit))
    }

    /// Lowercased ASCII letters and digits only, so "Al-Baqarah", "al baqarah" and "albaqara" compare well.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// 0 when the name or one of its parts ("Baqarah" in "Al-Baqarah") starts with the query.
    private static func rank(_ surah: Surah, _ needle: String) -> Int {
        let parts = [surah.nameSimple] + surah.nameSimple.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
        return parts.contains { normalized($0).hasPrefix(needle) } ? 0 : 1
    }
}

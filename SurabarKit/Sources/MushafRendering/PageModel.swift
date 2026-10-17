import Foundation

/// Ayah identity used everywhere outside the renderer. Never derived from page numbers.
public struct AyahKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let surah: Int
    public let ayah: Int

    public init(surah: Int, ayah: Int) {
        self.surah = surah
        self.ayah = ayah
    }

    public var description: String { "\(surah):\(ayah)" }

    /// Parses "surah:ayah".
    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let surah = Int(parts[0]), let ayah = Int(parts[1]), surah > 0, ayah > 0 else { return nil }
        self.init(surah: surah, ayah: ayah)
    }

    public static func < (lhs: AyahKey, rhs: AyahKey) -> Bool {
        (lhs.surah, lhs.ayah) < (rhs.surah, rhs.ayah)
    }
}

/// One shaped unit on a line: a source word, or decorative text such as a surah title.
public struct LineItem: Sendable, Hashable {
    /// Source text, drawn exactly as given unless the page is drawn with glyph fonts.
    public let text: String
    /// The layout's word index, or nil for decorative items.
    public let wordID: Int?
    public let ayah: AyahKey?
    /// Glyph codes for a page font (QCF), drawn instead of `text` when page fonts are available.
    /// `text` remains the word's identity for copying and accessibility.
    public let glyphs: String?

    public init(text: String, wordID: Int? = nil, ayah: AyahKey? = nil, glyphs: String? = nil) {
        self.text = text
        self.wordID = wordID
        self.ayah = ayah
        self.glyphs = glyphs
    }
}

public enum LineKind: String, Sendable {
    case ayah
    case surahName = "surah_name"
    case basmallah
}

public struct MushafLine: Sendable {
    public let number: Int
    public let kind: LineKind
    public let isCentered: Bool
    public let items: [LineItem]
    /// Set from the start (right) edge with natural spacing, as the last line of a paragraph is;
    /// otherwise a line is justified or centred.
    public let startsAtEdge: Bool

    public init(number: Int, kind: LineKind, isCentered: Bool, items: [LineItem], startsAtEdge: Bool = false) {
        self.number = number
        self.kind = kind
        self.isCentered = isCentered
        self.items = items
        self.startsAtEdge = startsAtEdge
    }
}

public struct MushafPage: Sendable {
    public let number: Int
    public let linesPerPage: Int
    public let lines: [MushafLine]

    public init(number: Int, linesPerPage: Int, lines: [MushafLine]) {
        self.number = number
        self.linesPerPage = linesPerPage
        self.lines = lines
    }
}

/// The reader widths from the product plan, in points.
public enum ReaderSize: String, CaseIterable, Sendable {
    case small = "S", medium = "M", large = "L"

    public var width: Double {
        switch self {
        case .small: 340
        case .medium: 440
        case .large: 560
        }
    }
}

import CoreText
import Foundation

public enum MushafFontError: Error, CustomStringConvertible {
    case unreadable(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): "No font could be read from \(url.path)"
        }
    }
}

/// A font loaded from a file without registering it process-wide.
public struct MushafFont: @unchecked Sendable {
    // CTFont is immutable and thread-safe; it is not annotated Sendable.
    private let base: CTFont
    public let postScriptName: String

    public init(url: URL) throws {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else { throw MushafFontError.unreadable(url) }
        self.init(CTFontCreateWithFontDescriptor(descriptor, 100, nil))
    }

    /// Wraps an installed font, used by tests and diagnostics.
    public init(name: String) {
        self.init(CTFontCreateWithName(name as CFString, 100, nil))
    }

    /// The system's Arabic interface font, for surah titles and other text that is not Quranic.
    /// SF Arabic cannot be requested by name, so take the font the system UI font cascades to for Arabic.
    /// Created once: creating system UI fonts on several threads at the same time can deadlock Core Text.
    public static let systemArabic: MushafFont = {
        let fallback = MushafFont(CTFontCreateWithName("GeezaPro" as CFString, 100, nil))
        guard let ui = CTFontCreateUIFontForLanguage(.system, 100, "ar" as CFString) else { return fallback }
        let probe = NSAttributedString(string: "ب", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ui])
        guard let run = (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(probe)) as? [CTRun])?.first,
              let attributes = CTRunGetAttributes(run) as? [String: Any],
              let font = attributes[kCTFontAttributeName as String] else { return fallback }
        return MushafFont(font as! CTFont)
    }()

    private init(_ font: CTFont) {
        base = font
        postScriptName = CTFontCopyPostScriptName(font) as String
    }

    public func sized(_ size: Double) -> CTFont {
        CTFontCreateCopyWithAttributes(base, size, nil, nil)
    }
}

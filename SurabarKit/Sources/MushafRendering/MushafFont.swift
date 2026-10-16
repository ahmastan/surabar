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

    private init(_ font: CTFont) {
        base = font
        postScriptName = CTFontCopyPostScriptName(font) as String
    }

    public func sized(_ size: Double) -> CTFont {
        CTFontCreateCopyWithAttributes(base, size, nil, nil)
    }
}

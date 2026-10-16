import CoreGraphics
import CoreText
import Foundation

/// Size-independent parameters; the font size follows from the page width.
public struct PageStyle: Sendable {
    /// Font size divided by the text column width. Chosen so the widest justified
    /// line of a layout fits with natural word spacing (see `Calibration`).
    public var calibration: Double
    public var horizontalInset: Double = 12
    public var verticalInset: Double = 10
    /// Multiplier on the font's ascent plus descent.
    public var lineSpacing: Double = 1.0

    public init(calibration: Double) {
        self.calibration = calibration
    }
}

/// Coordinates are in points with the origin at the page's top-left and y increasing downward.
public struct LaidOutItem: @unchecked Sendable {
    public let item: LineItem
    public let lineIndex: Int
    public let line: CTLine
    public let baseline: CGPoint
    /// Advance box: the area used for hit-testing and selection.
    public let typographicRect: CGRect
    /// Glyph outline bounds, including diacritics that extend past the advance box.
    public let inkRect: CGRect
    /// Characters drawn with a fallback font or as a missing glyph.
    public let missingCharacters: [Unicode.Scalar]
}

public struct LineReport: Sendable {
    public let lineIndex: Int
    /// Natural width minus available width; positive means the line does not fit.
    public let excessWidth: Double
    /// Space between words as a multiple of the font's space advance.
    public let gapRatio: Double
}

public struct LayoutDiagnostics: Sendable {
    public var overflowingLines: [LineReport] = []
    public var missingGlyphs: [(line: Int, text: String, scalars: [Unicode.Scalar])] = []
    /// Items whose ink extends outside the page and would be clipped.
    public var clippedItems: [(line: Int, text: String)] = []
    /// Neighbouring advance boxes that intersect. Should never happen.
    public var overlappingItems: [(line: Int, first: String, second: String)] = []
    /// Neighbouring ink boxes that intersect. Often harmless for Arabic; listed for review.
    public var inkContacts: [(line: Int, first: String, second: String)] = []
    public var lines: [LineReport] = []

    public var hasDefects: Bool {
        !overflowingLines.isEmpty || !missingGlyphs.isEmpty || !clippedItems.isEmpty || !overlappingItems.isEmpty
    }
}

public struct PageLayout: @unchecked Sendable {
    public let page: MushafPage
    public let size: CGSize
    public let fontSize: Double
    public let lineHeight: Double
    public let items: [LaidOutItem]
    public let diagnostics: LayoutDiagnostics

    /// The item under a point, using the full line band vertically.
    public func item(at point: CGPoint) -> LaidOutItem? {
        items.first { candidate in
            let band = candidate.typographicRect.insetBy(dx: 0, dy: (candidate.typographicRect.height - lineHeight) / 2)
            return band.contains(point)
        }
    }

    /// Visible fragments of an ayah on this page, one rectangle per line.
    public func rects(for ayah: AyahKey) -> [CGRect] {
        Dictionary(grouping: items.filter { $0.item.ayah == ayah }, by: \.lineIndex)
            .sorted { $0.key < $1.key }
            .map { $0.value.map(\.typographicRect).reduce(CGRect.null) { $0.union($1) } }
    }
}

public enum PageLayoutEngine {
    public static func layout(_ page: MushafPage, width: Double, font: MushafFont, style: PageStyle) -> PageLayout {
        let columnWidth = width - 2 * style.horizontalInset
        let fontSize = columnWidth * style.calibration
        let ctFont = font.sized(fontSize)
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let lineHeight = (ascent + descent) * style.lineSpacing
        let height = 2 * style.verticalInset + Double(page.linesPerPage) * lineHeight
        let pageRect = CGRect(x: 0, y: 0, width: width, height: height)
        // Short pages, such as the opening pages, are centred vertically.
        let top = style.verticalInset + Double(max(0, page.linesPerPage - page.lines.count)) * lineHeight / 2
        let spaceWidth = advance(of: " ", font: ctFont)

        var items: [LaidOutItem] = []
        var diagnostics = LayoutDiagnostics()
        for (lineIndex, line) in page.lines.enumerated() {
            let shaped = line.items.map { item -> (LineItem, CTLine, Double) in
                let ctLine = makeLine(item.text, font: ctFont)
                return (item, ctLine, CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            }
            let widths = shaped.reduce(0) { $0 + $1.2 }
            let gaps = Double(max(shaped.count - 1, 0))
            let natural = widths + gaps * spaceWidth
            let justify = !line.isCentered && shaped.count > 1
            let gap = justify ? (columnWidth - widths) / gaps : spaceWidth
            let used = widths + gaps * gap
            let report = LineReport(lineIndex: lineIndex, excessWidth: natural - columnWidth,
                                    gapRatio: spaceWidth > 0 ? gap / spaceWidth : 0)
            diagnostics.lines.append(report)
            if report.excessWidth > 0.01 { diagnostics.overflowingLines.append(report) }

            let baselineY = top + Double(lineIndex) * lineHeight + lineHeight * ascent / (ascent + descent)
            // Right-to-left: the first item starts at the right edge of the text column.
            var right = style.horizontalInset + columnWidth - (justify ? 0 : (columnWidth - used) / 2)
            var lineItems: [LaidOutItem] = []
            for (item, ctLine, itemWidth) in shaped {
                let x = right - itemWidth
                let ink = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
                let laidOut = LaidOutItem(
                    item: item, lineIndex: lineIndex, line: ctLine,
                    baseline: CGPoint(x: x, y: baselineY),
                    typographicRect: CGRect(x: x, y: baselineY - ascent, width: itemWidth, height: ascent + descent),
                    inkRect: ink.isNull ? .null : CGRect(x: x + ink.minX, y: baselineY - ink.maxY, width: ink.width, height: ink.height),
                    missingCharacters: missingCharacters(in: ctLine, text: item.text, expected: font.postScriptName))
                if !laidOut.missingCharacters.isEmpty {
                    diagnostics.missingGlyphs.append((lineIndex, item.text, laidOut.missingCharacters))
                }
                if !laidOut.inkRect.isNull, !pageRect.contains(laidOut.inkRect) {
                    diagnostics.clippedItems.append((lineIndex, item.text))
                }
                if let previous = lineItems.last {
                    if previous.typographicRect.minX < laidOut.typographicRect.maxX - 0.01 {
                        diagnostics.overlappingItems.append((lineIndex, previous.item.text, item.text))
                    }
                    if previous.inkRect.intersects(laidOut.inkRect) {
                        diagnostics.inkContacts.append((lineIndex, previous.item.text, item.text))
                    }
                }
                lineItems.append(laidOut)
                right = x - gap
            }
            items += lineItems
        }
        return PageLayout(page: page, size: pageRect.size, fontSize: fontSize, lineHeight: lineHeight,
                          items: items, diagnostics: diagnostics)
    }

    static func makeLine(_ text: String, font: CTFont) -> CTLine {
        var direction = CTWritingDirection.rightToLeft
        let paragraph = withUnsafeBytes(of: &direction) { bytes in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: bytes.count, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    }

    static func advance(of text: String, font: CTFont) -> Double {
        CTLineGetTypographicBounds(makeLine(text, font: font), nil, nil, nil)
    }

    /// Characters shaped with a substitute font or mapped to glyph 0.
    static func missingCharacters(in line: CTLine, text: String, expected: String) -> [Unicode.Scalar] {
        let utf16 = Array(text.utf16)
        var missing: [Unicode.Scalar] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            let substituted = CTFontCopyPostScriptName(runFont) as String != expected
            guard substituted || glyphs.contains(0) else { continue }
            let range = CTRunGetStringRange(run)
            let slice = String(decoding: utf16[range.location ..< range.location + range.length], as: UTF16.self)
            missing += slice.unicodeScalars
        }
        return missing
    }
}

/// Derives `PageStyle.calibration` from every justified line of a layout.
public enum Calibration {
    /// The ratio at which the widest justified line fits with natural word spacing.
    public static func ratio(for pages: [MushafPage], font: MushafFont) -> (ratio: Double, widestPage: Int, widestLine: Int) {
        let reference = 100.0
        let ctFont = font.sized(reference)
        let space = PageLayoutEngine.advance(of: " ", font: ctFont)
        var widest = (width: 0.0, page: 0, line: 0)
        for page in pages {
            for line in page.lines where !line.isCentered {
                let words = line.items.reduce(0) { $0 + PageLayoutEngine.advance(of: $1.text, font: ctFont) }
                let width = words + Double(max(line.items.count - 1, 0)) * space
                if width > widest.width { widest = (width, page.number, line.number) }
            }
        }
        return (widest.width > 0 ? reference / widest.width : 0, widest.page, widest.line)
    }
}

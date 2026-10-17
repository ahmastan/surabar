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
    /// Surah title size relative to the Quran text.
    public var titleScale: Double = 0.8
    /// Line pitch and baseline in ems, used instead of the font's ascent and descent.
    /// Page fonts differ slightly in their metrics, and every page of a layout must have the same height.
    public var lineMetrics: LineMetrics?
    /// Space between words on centred lines, in ems, for glyph fonts that have no space glyph.
    public var glyphWordGap: Double = 0.1
    /// Lets a line wider than the column shrink its font to fit, so the calibration can follow
    /// typical lines rather than the single widest one. Off: such a line is reported as overflowing.
    public var shrinksWideLines = false

    public init(calibration: Double, lineMetrics: LineMetrics? = nil) {
        self.calibration = calibration
        self.lineMetrics = lineMetrics
    }
}

public struct LineMetrics: Sendable, Hashable {
    /// Distance between baselines, in ems.
    public var lineHeight: Double
    /// Distance from the top of a line to its baseline, in ems.
    public var ascent: Double

    public init(lineHeight: Double, ascent: Double) {
        self.lineHeight = lineHeight
        self.ascent = ascent
    }
}

/// Fonts for a page drawn from glyph codes (QCF): the page's own font, and the font holding the
/// basmallah's glyphs (page 1's, since 1:1 is set there).
public struct GlyphFonts: Sendable {
    public let page: MushafFont
    public let basmallah: MushafFont

    public init(page: MushafFont, basmallah: MushafFont) {
        self.page = page
        self.basmallah = basmallah
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
    /// The line's font size relative to the page's; below 1 when a wide line was shrunk to fit.
    public var scale: Double = 1
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
    /// Where a note marker goes: just above the ayah's last item on the page (its number, when it ends here).
    public func markerPoint(for ayah: AyahKey) -> CGPoint? {
        guard let last = items.last(where: { $0.item.ayah == ayah }) else { return nil }
        return CGPoint(x: last.typographicRect.midX, y: last.typographicRect.minY + 3)
    }

    public func rects(for ayah: AyahKey) -> [CGRect] {
        Dictionary(grouping: items.filter { $0.item.ayah == ayah }, by: \.lineIndex)
            .sorted { $0.key < $1.key }
            .map { $0.value.map(\.typographicRect).reduce(CGRect.null) { $0.union($1) } }
    }
}

public enum PageLayoutEngine {
    /// Lays out a page. Surah titles use `titleFont`, because title text comes from metadata and may
    /// contain characters that a Quran font does not encode. With `glyphFonts`, words are drawn from
    /// their glyph codes in the page's own font; otherwise their text is drawn in `font`.
    public static func layout(_ page: MushafPage, width: Double, font: MushafFont, style: PageStyle,
                              titleFont: MushafFont = .systemArabic, glyphFonts: GlyphFonts? = nil) -> PageLayout {
        let columnWidth = width - 2 * style.horizontalInset
        let fontSize = columnWidth * style.calibration
        let ctFont = (glyphFonts?.page ?? font).sized(fontSize)
        let metrics = lineMetrics(fontSize: fontSize, font: font, style: style)
        let ascent = metrics.ascent
        let descent = metrics.lineHeight / style.lineSpacing - ascent
        let lineHeight = metrics.lineHeight
        let height = 2 * style.verticalInset + Double(page.linesPerPage) * lineHeight
        let pageRect = CGRect(x: 0, y: 0, width: width, height: height)
        // Short pages, such as the opening pages, are centred vertically.
        let top = style.verticalInset + Double(max(0, page.linesPerPage - page.lines.count)) * lineHeight / 2
        let spaceWidth = glyphFonts == nil ? advance(of: " ", font: ctFont) : style.glyphWordGap * fontSize
        let titleCTFont = titleFont.sized(fontSize * style.titleScale)
        let basmallahCTFont = glyphFonts.map { $0.basmallah.sized(fontSize) }

        var items: [LaidOutItem] = []
        var diagnostics = LayoutDiagnostics()
        for (lineIndex, line) in page.lines.enumerated() {
            let isTitle = line.kind == .surahName
            let isGlyphBasmallah = line.kind == .basmallah && glyphFonts != nil
            let lineFont = isTitle ? titleFont : isGlyphBasmallah ? glyphFonts!.basmallah : glyphFonts?.page ?? font
            let lineCTFont = isTitle ? titleCTFont : isGlyphBasmallah ? basmallahCTFont! : ctFont
            func shape(_ font: CTFont) -> [(LineItem, CTLine, Double, String)] {
                line.items.map { item in
                    let drawn = isTitle || glyphFonts == nil ? item.text : item.glyphs ?? item.text
                    let ctLine = makeLine(drawn, font: font)
                    return (item, ctLine, CTLineGetTypographicBounds(ctLine, nil, nil, nil), drawn)
                }
            }
            var shaped = shape(lineCTFont)
            var widths = shaped.reduce(0) { $0 + $1.2 }
            let gaps = Double(max(shaped.count - 1, 0))
            var natural = widths + gaps * spaceWidth
            var lineSpace = spaceWidth
            var scale = 1.0
            if style.shrinksWideLines, !isTitle, natural > columnWidth {
                // Shrink the words and their minimum spacing together, keeping the baseline.
                scale = columnWidth / natural
                shaped = shape(CTFontCreateCopyWithAttributes(lineCTFont, CTFontGetSize(lineCTFont) * scale, nil, nil))
                widths = shaped.reduce(0) { $0 + $1.2 }
                lineSpace = spaceWidth * scale
                natural = widths + gaps * lineSpace
            }
            let justify = !line.isCentered && !line.startsAtEdge && shaped.count > 1
            // Marks such as pause signs can reach past a word's advance; pull a justified line in just
            // enough that the ink of its outer words stays on the page.
            var rightPull = 0.0, leftPull = 0.0
            if justify, let first = shaped.first, let last = shaped.last {
                let firstInk = CTLineGetBoundsWithOptions(first.1, .useGlyphPathBounds)
                let lastInk = CTLineGetBoundsWithOptions(last.1, .useGlyphPathBounds)
                if !firstInk.isNull { rightPull = max(0, firstInk.maxX - first.2 - style.horizontalInset + 1) }
                if !lastInk.isNull { leftPull = max(0, -lastInk.minX - style.horizontalInset + 1) }
            }
            let gap = justify ? max((columnWidth - rightPull - leftPull - widths) / gaps, 0) : lineSpace
            let used = widths + gaps * gap
            var report = LineReport(lineIndex: lineIndex, excessWidth: natural - columnWidth,
                                    gapRatio: spaceWidth > 0 ? gap / spaceWidth : 0)
            report.scale = scale
            diagnostics.lines.append(report)
            if report.excessWidth > 0.01 { diagnostics.overflowingLines.append(report) }

            let baselineY = top + Double(lineIndex) * lineHeight + lineHeight * ascent / (ascent + descent)
            // Right-to-left: the first item starts at the right edge of the text column.
            var right = style.horizontalInset + columnWidth - (justify ? rightPull : line.startsAtEdge ? 0 : (columnWidth - used) / 2)
            var lineItems: [LaidOutItem] = []
            for (item, ctLine, itemWidth, drawn) in shaped {
                let x = right - itemWidth
                let ink = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
                let laidOut = LaidOutItem(
                    item: item, lineIndex: lineIndex, line: ctLine,
                    baseline: CGPoint(x: x, y: baselineY),
                    typographicRect: CGRect(x: x, y: baselineY - ascent, width: itemWidth, height: ascent + descent),
                    inkRect: ink.isNull ? .null : CGRect(x: x + ink.minX, y: baselineY - ink.maxY, width: ink.width, height: ink.height),
                    missingCharacters: missingCharacters(in: ctLine, text: drawn, expected: lineFont.postScriptName))
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

    /// Text that is not a mushaf page (such as the Manzil's passages), set in justified lines like one: the
    /// words fill each line with natural spacing, then the line is justified; the last line starts at the
    /// right edge. `ayahs` are the words of each ayah, in order.
    public static func flow(_ ayahs: [(ayah: AyahKey, words: [String])], width: Double, font: MushafFont,
                            style: PageStyle) -> PageLayout {
        let columnWidth = width - 2 * style.horizontalInset
        let ctFont = font.sized(columnWidth * style.calibration)
        let space = advance(of: " ", font: ctFont)
        var lines: [[LineItem]] = [[]]
        var used = 0.0
        for (ayah, words) in ayahs {
            for word in words {
                let width = advance(of: word, font: ctFont)
                let needed = lines[lines.count - 1].isEmpty ? width : used + space + width
                if needed > columnWidth, !lines[lines.count - 1].isEmpty {
                    lines.append([])
                    used = width
                } else {
                    used = needed
                }
                lines[lines.count - 1].append(LineItem(text: word, ayah: ayah))
            }
        }
        let mushafLines = lines.enumerated().map { index, items in
            MushafLine(number: index + 1, kind: .ayah, isCentered: false, items: items, startsAtEdge: index == lines.count - 1)
        }
        return layout(MushafPage(number: 0, linesPerPage: mushafLines.count, lines: mushafLines), width: width, font: font, style: style)
    }

    /// The height of a page laid out at `width`. Every page of a layout has the same height.
    public static func pageHeight(width: Double, linesPerPage: Int, font: MushafFont, style: PageStyle) -> Double {
        let metrics = lineMetrics(fontSize: (width - 2 * style.horizontalInset) * style.calibration, font: font, style: style)
        return 2 * style.verticalInset + Double(linesPerPage) * metrics.lineHeight
    }

    /// Line pitch (including `lineSpacing`) and ascent in points.
    static func lineMetrics(fontSize: Double, font: MushafFont, style: PageStyle) -> (lineHeight: Double, ascent: Double) {
        if let fixed = style.lineMetrics {
            return (fixed.lineHeight * fontSize * style.lineSpacing, fixed.ascent * fontSize)
        }
        let ctFont = font.sized(fontSize)
        return ((CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)) * style.lineSpacing, CTFontGetAscent(ctFont))
    }

    /// The widest page width, up to `maximumWidth`, whose page fits in `height`.
    /// Page height grows linearly with the text column, so this solves for the column directly.
    public static func width(fitting height: Double, maximumWidth: Double, linesPerPage: Int, font: MushafFont,
                             style: PageStyle) -> Double {
        let full = pageHeight(width: maximumWidth, linesPerPage: linesPerPage, font: font, style: style)
        guard full > height else { return maximumWidth }
        let perColumnPoint = (full - 2 * style.verticalInset) / (maximumWidth - 2 * style.horizontalInset)
        let column = max((height - 2 * style.verticalInset) / perColumnPoint, 1)
        return column + 2 * style.horizontalInset
    }

    /// A right-to-left line of `text` in `font`, as the layout shapes each item.
    public static func line(_ text: String, font: CTFont) -> CTLine {
        makeLine(text, font: font)
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
    /// The ratio at which the widest justified line fits with natural word spacing. With a `percentile`
    /// below 100, the ratio fits that share of lines; the rest need `PageStyle.shrinksWideLines`.
    public static func ratio(for pages: [MushafPage], font: MushafFont,
                             percentile: Double = 100) -> (ratio: Double, widestPage: Int, widestLine: Int) {
        let reference = 100.0
        let ctFont = font.sized(reference)
        let space = PageLayoutEngine.advance(of: " ", font: ctFont)
        var lines: [(width: Double, page: Int, line: Int)] = []
        for page in pages {
            for line in page.lines where !line.isCentered {
                let words = line.items.reduce(0) { $0 + PageLayoutEngine.advance(of: $1.text, font: ctFont) }
                lines.append((words + Double(max(line.items.count - 1, 0)) * space, page.number, line.number))
            }
        }
        guard !lines.isEmpty else { return (0, 0, 0) }
        lines.sort { $0.width < $1.width }
        let index = Int((Double(lines.count - 1) * min(max(percentile, 0), 100) / 100).rounded(.down))
        let chosen = lines[index]
        return (chosen.width > 0 ? reference / chosen.width : 0, chosen.page, chosen.line)
    }

    /// The ratio at which the widest justified line fits when drawn from glyph codes in each page's font,
    /// with `wordGap` ems between words.
    public static func glyphRatio(for pages: [MushafPage], fonts: (Int) -> MushafFont,
                                  wordGap: Double) -> (ratio: Double, widestPage: Int, widestLine: Int) {
        let reference = 100.0
        var widest = (width: 0.0, page: 0, line: 0)
        for page in pages {
            let ctFont = fonts(page.number).sized(reference)
            for line in page.lines where !line.isCentered && line.kind == .ayah {
                let words = line.items.reduce(0) { $0 + PageLayoutEngine.advance(of: $1.glyphs ?? $1.text, font: ctFont) }
                let width = words + Double(max(line.items.count - 1, 0)) * wordGap * reference
                if width > widest.width { widest = (width, page.number, line.number) }
            }
        }
        return (widest.width > 0 ? reference / widest.width : 0, widest.page, widest.line)
    }
}

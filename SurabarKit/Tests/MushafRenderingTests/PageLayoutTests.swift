import CoreGraphics
import CoreText
import Foundation
import MushafRendering
import Testing

// Synthetic, non-Quranic Arabic set in a font that ships with macOS.
private let arabic = MushafFont(name: "GeezaPro")
private let words = ["هذا", "نص", "تجريبي", "لاختبار", "محاذاة", "الأسطر"]

private func line(_ number: Int, centered: Bool, count: Int = words.count) -> MushafLine {
    let items = words.prefix(count).enumerated().map { index, text in
        LineItem(text: text, wordID: number * 100 + index, ayah: AyahKey(surah: 1, ayah: number))
    }
    return MushafLine(number: number, kind: .ayah, isCentered: centered, items: Array(items))
}

private func layout(_ lines: [MushafLine], width: Double = ReaderSize.medium.width, scale: Double = 0.9,
                    font: MushafFont = arabic) -> PageLayout {
    let page = MushafPage(number: 1, linesPerPage: 15, lines: lines)
    let ratio = Calibration.ratio(for: [page], font: font).ratio
    return PageLayoutEngine.layout(page, width: width, font: font, style: PageStyle(calibration: ratio * scale))
}

@Test func justifiedLineFillsColumnRightToLeft() {
    let result = layout([line(1, centered: false)])
    let items = result.items
    let style = PageStyle(calibration: 0)
    #expect(abs(items.first!.typographicRect.maxX - (result.size.width - style.horizontalInset)) < 0.01)
    #expect(abs(items.last!.typographicRect.minX - style.horizontalInset) < 0.01)
    for (right, left) in zip(items, items.dropFirst()) {
        #expect(left.typographicRect.maxX < right.typographicRect.minX, "first word is rightmost; no overlaps")
    }
    #expect(!result.diagnostics.hasDefects)
}

@Test func calibratedWidestLineUsesNaturalSpacing() {
    let result = layout([line(1, centered: false), line(2, centered: false, count: 4)], scale: 1)
    #expect(abs(result.diagnostics.lines[0].gapRatio - 1) < 0.001)
    #expect(result.diagnostics.lines[1].gapRatio > 1)
    #expect(result.diagnostics.overflowingLines.isEmpty)
}

@Test func centeredLineIsCenteredWithNaturalSpacing() {
    let result = layout([line(1, centered: false), line(2, centered: true, count: 3)])
    let centered = result.items.filter { $0.lineIndex == 1 }
    let span = centered.map(\.typographicRect).reduce(CGRect.null) { $0.union($1) }
    #expect(abs(span.midX - result.size.width / 2) < 0.01)
    #expect(abs(result.diagnostics.lines[1].gapRatio - 1) < 0.001)
}

@Test func linesAreStackedAndShortPagesCentredVertically() {
    let result = layout([line(1, centered: false), line(2, centered: false)])
    let first = result.items.first { $0.lineIndex == 0 }!
    let second = result.items.first { $0.lineIndex == 1 }!
    #expect(abs(second.baseline.y - first.baseline.y - result.lineHeight) < 0.001)
    let middle = (first.baseline.y + second.baseline.y) / 2
    #expect(abs(middle - result.size.height / 2) < result.lineHeight)
}

@Test func overflowIsReportedWhenCalibrationIsTooLarge() {
    let result = layout([line(1, centered: false)], scale: 1.2)
    #expect(result.diagnostics.overflowingLines.count == 1)
    #expect(result.diagnostics.hasDefects)
}

@Test func missingGlyphsAreReportedForFallbackShaping() {
    let latinOnly = MushafFont(name: "Courier")
    let result = layout([line(1, centered: false, count: 2)], font: latinOnly)
    #expect(!result.diagnostics.missingGlyphs.isEmpty)
    #expect(result.diagnostics.missingGlyphs[0].scalars.contains("ه"))
}

@Test func hitTestingAndAyahRectsUseSourceIdentity() {
    let result = layout([line(1, centered: false), line(2, centered: false)])
    let target = result.items[8]
    let hit = result.item(at: CGPoint(x: target.typographicRect.midX, y: target.baseline.y))
    #expect(hit?.item.wordID == target.item.wordID)
    let rects = result.rects(for: AyahKey(surah: 1, ayah: 2))
    #expect(rects.count == 1)
    #expect(rects[0].contains(target.typographicRect))
    #expect(AyahKey(surah: 2, ayah: 255).description == "2:255")
}

@Test func rendersPNG() throws {
    let result = layout([line(1, centered: false)])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-test-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try PageRenderer.writePNG(result, to: url, scale: 1)
    let data = try Data(contentsOf: url)
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
}

@Test func surahTitlesUseTheTitleFont() {
    // A Latin-only page font would report missing glyphs if it were used for the Arabic title.
    let title = MushafLine(number: 1, kind: .surahName, isCentered: true, items: [LineItem(text: "سورة آل عمران")])
    let page = MushafPage(number: 1, linesPerPage: 15, lines: [title, line(2, centered: false)])
    let result = PageLayoutEngine.layout(page, width: 440, font: arabic, style: PageStyle(calibration: 0.03))
    #expect(result.diagnostics.missingGlyphs.isEmpty)
    let titleItem = result.items.first { $0.lineIndex == 0 }!
    let wordItem = result.items.first { $0.lineIndex == 1 }!
    #expect(titleItem.typographicRect.height < wordItem.typographicRect.height * 1.5)
}

@Test func pageHeightMatchesLayoutAndFittingWidthFits() {
    let page = MushafPage(number: 1, linesPerPage: 15, lines: [line(1, centered: false)])
    let style = PageStyle(calibration: Calibration.ratio(for: [page], font: arabic).ratio)
    let laidOut = PageLayoutEngine.layout(page, width: 440, font: arabic, style: style)
    let height = PageLayoutEngine.pageHeight(width: 440, linesPerPage: 15, font: arabic, style: style)
    #expect(abs(height - Double(laidOut.size.height)) < 0.001)
    #expect(PageLayoutEngine.width(fitting: height + 50, maximumWidth: 440, linesPerPage: 15, font: arabic, style: style) == 440)
    let narrower = PageLayoutEngine.width(fitting: height * 0.7, maximumWidth: 440, linesPerPage: 15, font: arabic, style: style)
    #expect(narrower < 440)
    let fitted = PageLayoutEngine.pageHeight(width: narrower, linesPerPage: 15, font: arabic, style: style)
    #expect(abs(fitted - height * 0.7) < 0.5)
}

@Test func wideLinesShrinkToFitWhenAllowed() {
    let page = MushafPage(number: 1, linesPerPage: 15, lines: [line(1, centered: false), line(2, centered: false, count: 3)])
    var style = PageStyle(calibration: Calibration.ratio(for: [page], font: arabic).ratio * 1.2)
    #expect(!PageLayoutEngine.layout(page, width: 440, font: arabic, style: style).diagnostics.overflowingLines.isEmpty)
    style.shrinksWideLines = true
    let result = PageLayoutEngine.layout(page, width: 440, font: arabic, style: style)
    #expect(result.diagnostics.overflowingLines.isEmpty)
    #expect(abs(result.diagnostics.lines[0].scale - 1 / 1.2) < 0.01)
    #expect(result.diagnostics.lines[1].scale == 1, "lines that fit keep the page's font size")
    let first = result.items.filter { $0.lineIndex == 0 }
    #expect(first.allSatisfy { $0.typographicRect.minX >= style.horizontalInset - 0.01 })
}

@Test func percentileCalibrationFitsThatShareOfLines() {
    let lines = (1 ... 10).map { line($0, centered: false, count: $0 == 10 ? words.count : 3) }
    let page = MushafPage(number: 1, linesPerPage: 15, lines: lines)
    let widest = Calibration.ratio(for: [page], font: arabic)
    let typical = Calibration.ratio(for: [page], font: arabic, percentile: 80)
    #expect(widest.widestLine == 10)
    #expect(typical.ratio > widest.ratio)
}

@Test func glyphFontsDrawGlyphCodesWithFixedLineMetrics() {
    // A stand-in "page font": glyph codes here are ordinary letters, drawn instead of the item text.
    let items = ["ا", "ب", "ت"].enumerated().map { index, glyph in
        LineItem(text: words[index], wordID: index, ayah: AyahKey(surah: 1, ayah: 1), glyphs: glyph)
    }
    let page = MushafPage(number: 1, linesPerPage: 15, lines: [MushafLine(number: 1, kind: .ayah, isCentered: false, items: items)])
    let style = PageStyle(calibration: 0.05, lineMetrics: LineMetrics(lineHeight: 1.8, ascent: 1.2))
    let fonts = GlyphFonts(page: arabic, basmallah: arabic)
    let result = PageLayoutEngine.layout(page, width: 440, font: MushafFont(name: "Courier"), style: style, glyphFonts: fonts)
    let fontSize = (440 - 2 * style.horizontalInset) * 0.05
    #expect(abs(result.lineHeight - 1.8 * fontSize) < 0.001)
    #expect(abs(PageLayoutEngine.pageHeight(width: 440, linesPerPage: 15, font: arabic, style: style)
        - (2 * style.verticalInset + 15 * 1.8 * fontSize)) < 0.001)
    #expect(result.items.map { CTLineGetGlyphCount($0.line) } == [1, 1, 1], "each item draws its one glyph code")
    #expect(result.items.map(\.item.text) == Array(words.prefix(3)), "the source text stays the item's identity")
    #expect(result.diagnostics.missingGlyphs.isEmpty)
}

@Test func flowedTextFillsJustifiedLinesAndEndsAtTheRightEdge() {
    // Five "ayahs" of the six sample words, at a width that holds a few words per line.
    let ayahs = (1 ... 5).map { (ayah: AyahKey(surah: 1, ayah: $0), words: words) }
    let style = PageStyle(calibration: 0.06)
    let result = PageLayoutEngine.flow(ayahs, width: 320, font: arabic, style: style)
    let lines = Dictionary(grouping: result.items, by: \.lineIndex).sorted { $0.key < $1.key }.map(\.value)
    #expect(lines.count > 2, "the words wrap onto several lines")
    #expect(result.items.count == 30, "every word is set once, in order")
    #expect(result.items.map(\.item.text) == Array(repeating: words, count: 5).flatMap { $0 })
    #expect(result.diagnostics.overflowingLines.isEmpty)
    let right = 320 - style.horizontalInset, left = style.horizontalInset
    for line in lines.dropLast() {
        #expect(abs(line.first!.typographicRect.maxX - right) < 0.5, "justified lines start at the right edge")
        #expect(abs(line.last!.typographicRect.minX - left) < 0.5, "and end at the left edge")
    }
    let last = lines.last!
    #expect(abs(last.first!.typographicRect.maxX - right) < 0.5, "the last line starts at the right edge")
    #expect(last.last!.typographicRect.minX > left + 1 || last.count == 1, "with natural spacing, not stretched")
    #expect(result.size.height > 0 && result.rects(for: AyahKey(surah: 1, ayah: 3)).count >= 1)
}

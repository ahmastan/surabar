import CoreGraphics
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

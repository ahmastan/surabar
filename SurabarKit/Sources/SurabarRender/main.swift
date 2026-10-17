import CoreText
import Foundation
import MushafRendering
import QuranStore

let usage = """
Usage:
  surabar-render calibrate --db FILE --layout ID --font FILE [--percentile P] [--page-fonts DIR] [--word-gap EM]
  surabar-render render    --db FILE --layout ID --font FILE --pages 1,2,50 --out DIR [--sizes S,M,L] [--calibration X] [--outline]
  surabar-render check     --db FILE --layout ID --font FILE [--sizes S,M,L] [--calibration X] [--touching]
  surabar-render sample    --font FILE|NAME --out DIR [--sizes S,M,L] [--outline]

With --page-fonts DIR (a layout with one font per page, such as QCF V2), words are drawn from their
glyph codes in DIR's page fonts; --font is then only used for the fallback. As in the app, lines wider
than the column shrink to fit; a line shrunk below 85% counts as a defect. --line-height EM and
--ascent EM override the stored line metrics.

calibrate  prints the font-size-to-column-width ratio at which the widest justified line fits;
           with page fonts, also the line metrics measured over every page.
render     writes PNG snapshots and a diagnostics summary for the given pages.
check      lays out every page at each size and exits 1 if any page has a defect; --touching also
           rasterizes each line and reports ink that touches the next line.
sample     renders synthetic non-Quranic Arabic to exercise the harness without a database.
"""

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw UsageError(description: "Unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if ["outline", "touching"].contains(name) { flags.insert(name); continue }
            guard let value = iterator.next() else { throw UsageError(description: "Missing value for \(argument)") }
            values[name] = value
        }
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name] else { throw UsageError(description: "Missing --\(name)") }
        return value
    }

    func sizes() throws -> [ReaderSize] {
        try (values["sizes"] ?? "S,M,L").split(separator: ",").map {
            guard let size = ReaderSize(rawValue: String($0)) else { throw UsageError(description: "Unknown size \($0)") }
            return size
        }
    }

    func url(_ name: String) throws -> URL { URL(fileURLWithPath: try required(name)) }
}

func loadFont(_ value: String) throws -> MushafFont {
    FileManager.default.fileExists(atPath: value) ? try MushafFont(url: URL(fileURLWithPath: value)) : MushafFont(name: value)
}

/// Page fonts loaded from a directory by the file names the database lists.
final class PageFontDirectory {
    let directory: URL
    let files: [Int: String]
    private var cache: [Int: MushafFont] = [:]

    init(directory: URL, store: QuranStore, layout: LayoutInfo) throws {
        self.directory = directory
        files = Dictionary(uniqueKeysWithValues: try store.pageFontFiles(of: layout).map { ($0.page, $0.file) })
        guard !files.isEmpty else { throw UsageError(description: "Layout \(layout.id) has no page fonts") }
    }

    func font(_ page: Int) throws -> MushafFont {
        if let font = cache[page] { return font }
        guard let file = files[page] else { throw UsageError(description: "No page font for page \(page)") }
        let font = try MushafFont(url: directory.appendingPathComponent(file))
        cache[page] = font
        return font
    }

    func glyphFonts(_ page: Int) throws -> GlyphFonts {
        GlyphFonts(page: try font(page), basmallah: try font(1))
    }
}

func pageFonts(_ options: Options, store: QuranStore, layout: LayoutInfo) throws -> PageFontDirectory? {
    guard options.values["page-fonts"] != nil else { return nil }
    return try PageFontDirectory(directory: try options.url("page-fonts"), store: store, layout: layout)
}

func allPages(_ store: QuranStore, _ layout: LayoutInfo) throws -> [MushafPage] {
    try (1 ... layout.pageCount).map { try store.page($0, of: layout) }
}

func style(_ options: Options, layout: LayoutInfo, pages: () throws -> [MushafPage], font: MushafFont,
           paged: PageFontDirectory?) throws -> PageStyle {
    if let paged, let settings = layout.pageFonts {
        let metrics = LineMetrics(lineHeight: options.values["line-height"].flatMap(Double.init) ?? settings.lineHeight,
                                  ascent: options.values["ascent"].flatMap(Double.init) ?? settings.ascent)
        var style = PageStyle(calibration: settings.calibration, lineMetrics: metrics)
        style.shrinksWideLines = true
        if let value = options.values["word-gap"], let gap = Double(value) { style.glyphWordGap = gap }
        if let value = options.values["calibration"], let ratio = Double(value) {
            style.calibration = ratio
        } else if settings.calibration <= 0 {
            let result = Calibration.glyphRatio(for: try pages(), fonts: { try! paged.font($0) }, wordGap: style.glyphWordGap)
            print("calibration \(result.ratio) (not stored; computed from page \(result.widestPage) line \(result.widestLine))")
            style.calibration = result.ratio
        }
        return style
    }
    var style = PageStyle(calibration: 0)
    style.shrinksWideLines = true
    if let value = options.values["calibration"], let ratio = Double(value) {
        style.calibration = ratio
    } else if let ratio = layout.calibration {
        style.calibration = ratio
    } else {
        let result = Calibration.ratio(for: try pages(), font: font)
        print("calibration \(result.ratio) (not stored; computed from page \(result.widestPage) line \(result.widestLine))")
        style.calibration = result.ratio
    }
    return style
}

/// Lines may shrink to fit the column (see `PageStyle.shrinksWideLines`), but not noticeably.
let minimumLineScale = 0.85

func summary(_ layout: PageLayout, label: String) -> [String] {
    let d = layout.diagnostics
    var lines: [String] = []
    for report in d.overflowingLines {
        lines.append("\(label) line \(report.lineIndex + 1): overflow by \(String(format: "%.2f", report.excessWidth)) pt")
    }
    for missing in d.missingGlyphs {
        let codes = missing.scalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        lines.append("\(label) line \(missing.line + 1): missing glyphs \(codes) in \(missing.text)")
    }
    for report in d.lines where report.scale < minimumLineScale {
        lines.append("\(label) line \(report.lineIndex + 1): shrunk to \(Int(report.scale * 100))% to fit")
    }
    for clipped in d.clippedItems { lines.append("\(label) line \(clipped.line + 1): ink clipped at page edge: \(clipped.text)") }
    for overlap in d.overlappingItems { lines.append("\(label) line \(overlap.line + 1): words overlap: \(overlap.first) / \(overlap.second)") }
    return lines
}

/// Ink extents over every page in ems, and the tightest line pitch at which no two vertically
/// adjacent words' ink would touch.
func measureLineMetrics(_ pages: [MushafPage], fonts: PageFontDirectory) throws -> String {
    var ascent = 0.0, descent = 0.0, inkTop = 0.0, inkBottom = 0.0, pitch = 0.0
    var tightest = ""
    for page in pages {
        let size = 100.0
        let font = try fonts.font(page.number).sized(size)
        ascent = max(ascent, CTFontGetAscent(font) / size)
        descent = max(descent, CTFontGetDescent(font) / size)
        // Each line's ink, measured from its baseline, with horizontal positions at natural spacing.
        var previous: [(CGRect)] = []
        for line in page.lines where line.kind == .ayah {
            var x = 0.0
            var boxes: [CGRect] = []
            for item in line.items {
                let ctLine = PageLayoutEngine.line(item.glyphs ?? item.text, font: font)
                let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                let ink = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
                boxes.append(CGRect(x: x + ink.minX, y: ink.minY, width: ink.width, height: ink.height))
                inkTop = max(inkTop, ink.maxY / size)
                inkBottom = max(inkBottom, -ink.minY / size)
                x += width
            }
            // Lines are justified to the same width; compare boxes by their share of the line.
            let total = max(x, 1)
            let scaled = boxes.map { CGRect(x: $0.minX / total, y: $0.minY, width: $0.width / total, height: $0.height) }
            for upper in previous {
                for lower in scaled where upper.minX < lower.maxX && lower.minX < upper.maxX {
                    let needed = (lower.maxY - upper.minY) / size
                    if needed > pitch { pitch = needed; tightest = "page \(page.number) line \(line.number)" }
                }
            }
            previous = scaled
        }
    }
    return String(format: "font ascent max %.3f em, descent max %.3f em; ink top %.3f em, bottom %.3f em; "
                  + "minimum pitch without touching ink %.3f em (at %@)", ascent, descent, inkTop, inkBottom, pitch, tightest)
}

/// Lines whose ink touches the next line's ink, found by rasterizing each line on its own.
func touchingLines(_ layout: PageLayout, scale: Double = 2) -> [Int] {
    let width = Int((layout.size.width * scale).rounded(.up))
    let height = Int((layout.size.height * scale).rounded(.up))
    func mask(_ line: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 1, alpha: 1)
            context.textMatrix = .identity
            for item in layout.items where item.lineIndex == line {
                context.textPosition = CGPoint(x: item.baseline.x, y: layout.size.height - item.baseline.y)
                CTLineDraw(item.line, context)
            }
        }
        return pixels
    }
    let lines = Set(layout.items.map(\.lineIndex)).sorted()
    var touching: [Int] = []
    var previous: (index: Int, pixels: [UInt8])?
    for line in lines {
        let pixels = mask(line)
        if let previous, previous.index == line - 1,
           zip(previous.pixels, pixels).contains(where: { $0 > 64 && $1 > 64 }) {
            touching.append(previous.index)
        }
        previous = (line, pixels)
    }
    return touching
}

func gapSummary(_ layout: PageLayout) -> String {
    let ratios = layout.diagnostics.lines.map(\.gapRatio)
    let shrunk = layout.diagnostics.lines.filter { $0.scale < 1 }
    return String(format: "font %.2f pt, page %.0fx%.0f pt, word gaps %.2f–%.2f× space, ink contacts %d",
                  layout.fontSize, layout.size.width, layout.size.height,
                  ratios.min() ?? 0, ratios.max() ?? 0, layout.diagnostics.inkContacts.count)
        + (shrunk.isEmpty ? "" : String(format: ", %d lines shrunk (smallest %.0f%%)", shrunk.count,
                                        (shrunk.map(\.scale).min() ?? 1) * 100))
}

func sampleText() -> MushafPage {
    // Ordinary Arabic phrases for exercising layout; deliberately not Quranic text.
    let words = ["هذا", "نص", "تجريبي", "لاختبار", "محاذاة", "الأسطر", "وتوزيع", "المسافات", "بين", "الكلمات",
                 "في", "صفحة", "مكونة", "من", "خمسة", "عشر", "سطرا", "بدون", "استخدام", "أي", "نص", "مصدري"]
    let lines = (0 ..< 15).map { index -> MushafLine in
        if index == 0 { return MushafLine(number: 1, kind: .surahName, isCentered: true, items: [LineItem(text: "عنوان تجريبي")]) }
        let count = index == 14 ? 3 : 7 + index % 3
        let items = (0 ..< count).map { LineItem(text: words[(index * 5 + $0) % words.count], wordID: index * 10 + $0) }
        return MushafLine(number: index + 1, kind: .ayah, isCentered: index == 14, items: items)
    }
    return MushafPage(number: 1, linesPerPage: 15, lines: lines)
}

func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { print(usage); return 2 }
    let options = try Options(arguments.dropFirst(2))
    switch arguments[1] {
    case "calibrate":
        let store = try QuranStore(url: try options.url("db"))
        let layout = try store.layout(try options.required("layout"))
        let font = try loadFont(try options.required("font"))
        let pages = try allPages(store, layout)
        let percentile = options.values["percentile"].flatMap(Double.init) ?? 100
        let result = Calibration.ratio(for: pages, font: font, percentile: percentile)
        print("\(layout.id) font calibration \(result.ratio) fitting \(percentile)% of lines (at: page \(result.widestPage) line \(result.widestLine))")
        if let paged = try pageFonts(options, store: store, layout: layout) {
            let gap = options.values["word-gap"].flatMap(Double.init) ?? PageStyle(calibration: 0).glyphWordGap
            let glyph = Calibration.glyphRatio(for: pages, fonts: { try! paged.font($0) }, wordGap: gap)
            print("\(layout.id) page font calibration \(glyph.ratio) with word gap \(gap) em (widest: page \(glyph.widestPage) line \(glyph.widestLine))")
            print(try measureLineMetrics(pages, fonts: paged))
        }
        return 0

    case "render", "check":
        let store = try QuranStore(url: try options.url("db"))
        let layout = try store.layout(try options.required("layout"))
        let font = try loadFont(try options.required("font"))
        let paged = try pageFonts(options, store: store, layout: layout)
        if !layout.verified { print("warning: layout \(layout.id) is NOT verified") }
        var cached: [MushafPage]?
        let pages = { () throws -> [MushafPage] in
            if let cached { return cached }
            cached = try allPages(store, layout)
            return cached!
        }
        let pageStyle = try style(options, layout: layout, pages: pages, font: font, paged: paged)
        var defects: [String] = []
        if arguments[1] == "check" {
            for size in try options.sizes() {
                var contacts = 0
                for page in try pages() {
                    let result = PageLayoutEngine.layout(page, width: size.width, font: font, style: pageStyle,
                                                         glyphFonts: try paged?.glyphFonts(page.number))
                    defects += summary(result, label: "\(size.rawValue) page \(page.number)")
                    contacts += result.diagnostics.inkContacts.count
                    if options.flags.contains("touching") {
                        defects += touchingLines(result).map { "\(size.rawValue) page \(page.number) line \($0 + 1): ink touches the next line" }
                    }
                }
                print("\(size.rawValue): checked \(layout.pageCount) pages; neighbouring ink contacts for review: \(contacts)")
            }
        } else {
            let out = try options.url("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let numbers = try options.required("pages").split(separator: ",").compactMap { Int($0) }
            for number in numbers {
                let page = try store.page(number, of: layout)
                for size in try options.sizes() {
                    let result = PageLayoutEngine.layout(page, width: size.width, font: font, style: pageStyle,
                                                         glyphFonts: try paged?.glyphFonts(number))
                    let file = out.appendingPathComponent(String(format: "%@-p%03d-%@.png", layout.id, number, size.rawValue))
                    try PageRenderer.writePNG(result, to: file, outlineItems: options.flags.contains("outline"))
                    print("\(file.lastPathComponent): \(gapSummary(result))")
                    defects += summary(result, label: "\(size.rawValue) page \(number)")
                }
            }
        }
        defects.forEach { print("DEFECT \($0)") }
        print(defects.isEmpty ? "no defects found" : "\(defects.count) defects found")
        return defects.isEmpty ? 0 : 1

    case "sample":
        let font = try loadFont(try options.required("font"))
        let out = try options.url("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let page = sampleText()
        let pageStyle = PageStyle(calibration: Calibration.ratio(for: [page], font: font).ratio)
        var defects: [String] = []
        for size in try options.sizes() {
            let result = PageLayoutEngine.layout(page, width: size.width, font: font, style: pageStyle)
            let file = out.appendingPathComponent("sample-\(size.rawValue).png")
            try PageRenderer.writePNG(result, to: file, outlineItems: options.flags.contains("outline"))
            print("\(file.lastPathComponent): \(gapSummary(result))")
            defects += summary(result, label: size.rawValue)
        }
        defects.forEach { print("DEFECT \($0)") }
        return defects.isEmpty ? 0 : 1

    default:
        print(usage)
        return 2
    }
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

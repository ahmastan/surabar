import Foundation
import MushafRendering
import QuranStore

let usage = """
Usage:
  surabar-render calibrate --db FILE --layout ID --font FILE
  surabar-render render    --db FILE --layout ID --font FILE --pages 1,2,50 --out DIR [--sizes S,M,L] [--calibration X] [--outline]
  surabar-render check     --db FILE --layout ID --font FILE [--sizes S,M,L] [--calibration X]
  surabar-render sample    --font FILE|NAME --out DIR [--sizes S,M,L] [--outline]

calibrate  prints the font-size-to-column-width ratio at which the widest justified line fits.
render     writes PNG snapshots and a diagnostics summary for the given pages.
check      lays out every page at each size and exits 1 if any page has a defect.
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
            if name == "outline" { flags.insert(name); continue }
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

func allPages(_ store: QuranStore, _ layout: LayoutInfo) throws -> [MushafPage] {
    try (1 ... layout.pageCount).map { try store.page($0, of: layout) }
}

func style(_ options: Options, layout: LayoutInfo, pages: () throws -> [MushafPage], font: MushafFont) throws -> PageStyle {
    if let value = options.values["calibration"], let ratio = Double(value) { return PageStyle(calibration: ratio) }
    if let ratio = layout.calibration { return PageStyle(calibration: ratio) }
    let result = Calibration.ratio(for: try pages(), font: font)
    print("calibration \(result.ratio) (not stored; computed from page \(result.widestPage) line \(result.widestLine))")
    return PageStyle(calibration: result.ratio)
}

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
    for clipped in d.clippedItems { lines.append("\(label) line \(clipped.line + 1): ink clipped at page edge: \(clipped.text)") }
    for overlap in d.overlappingItems { lines.append("\(label) line \(overlap.line + 1): words overlap: \(overlap.first) / \(overlap.second)") }
    return lines
}

func gapSummary(_ layout: PageLayout) -> String {
    let ratios = layout.diagnostics.lines.map(\.gapRatio)
    return String(format: "font %.2f pt, page %.0fx%.0f pt, word gaps %.2f–%.2f× space, ink contacts %d",
                  layout.fontSize, layout.size.width, layout.size.height,
                  ratios.min() ?? 0, ratios.max() ?? 0, layout.diagnostics.inkContacts.count)
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
        let result = Calibration.ratio(for: try allPages(store, layout), font: font)
        print("\(layout.id) calibration \(result.ratio) (widest: page \(result.widestPage) line \(result.widestLine))")
        return 0

    case "render", "check":
        let store = try QuranStore(url: try options.url("db"))
        let layout = try store.layout(try options.required("layout"))
        let font = try loadFont(try options.required("font"))
        if !layout.verified { print("warning: layout \(layout.id) is NOT verified") }
        var cached: [MushafPage]?
        let pages = { () throws -> [MushafPage] in
            if let cached { return cached }
            cached = try allPages(store, layout)
            return cached!
        }
        let pageStyle = try style(options, layout: layout, pages: pages, font: font)
        var defects: [String] = []
        if arguments[1] == "check" {
            for size in try options.sizes() {
                var contacts = 0
                for page in try pages() {
                    let result = PageLayoutEngine.layout(page, width: size.width, font: font, style: pageStyle)
                    defects += summary(result, label: "\(size.rawValue) page \(page.number)")
                    contacts += result.diagnostics.inkContacts.count
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
                    let result = PageLayoutEngine.layout(page, width: size.width, font: font, style: pageStyle)
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

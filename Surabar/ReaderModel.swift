import AppKit
import MushafRendering
import Observation
import QuranStore
import Recitation

/// Reading state and navigation shared by every reader surface. Positions are kept as ayahs;
/// page numbers are only ever looked up for the current layout.
@MainActor
@Observable
final class ReaderModel {
    enum Overlay: Equatable {
        case surahPicker
        case jump
        /// Bookmarks, highlights, and notes.
        case annotations
        /// Editing the note on an ayah.
        case note(AyahKey)
    }

    let state: AppState
    let library: QuranLibrary?
    let loadError: String?
    var overlay: Overlay?
    /// The main area shows the Manzil, scrolling, instead of the mushaf page.
    private(set) var readingManzil = false {
        didSet { if oldValue && !readingManzil { leftManzil?() } }
    }
    /// Called when the reader leaves the Manzil; set by the app.
    @ObservationIgnored var leftManzil: (() -> Void)?

    /// The direction of the last page change: +1 forward (the next page), −1 back, 0 for a jump to
    /// another script or the first load. The page slides in from that side.
    private(set) var lastTurn = 0
    /// Whether the page and selection follow the recited ayah. Turning pages, jumping, or selecting
    /// another ayah stops following until playback is moved or "Back to playing" is chosen.
    var followsPlayback = true
    /// Starts recitation at an ayah (the page's "Play from Here"); set by the app.
    @ObservationIgnored var playAyah: ((AyahKey) -> Void)?
    /// Loops a range of ayahs ("Loop to Here"); set by the app.
    @ObservationIgnored var loopAyahs: ((ClosedRange<AyahKey>) -> Void)?
    /// Translations (QuranEnc.com); set by the app.
    @ObservationIgnored var translations: TranslationLibrary?
    /// Bookmarks, highlights, and notes; nil when the store could not be opened.
    @ObservationIgnored var annotations: AnnotationStore?
    /// Downloadable page fonts by layout id, for layouts drawn with one font per page.
    let pageFonts: [String: PageFontStore]

    @ObservationIgnored private var pageCache: [String: MushafPage] = [:]
    @ObservationIgnored private var layoutCache: [String: PageLayout] = [:]
    @ObservationIgnored private var manzilLayouts: [String: PageLayout] = [:]
    @ObservationIgnored private var juzCache: [Int: [(surah: Surah, ayahs: ClosedRange<Int>)]] = [:]
    /// Neighbouring pages being laid out in the background.
    @ObservationIgnored private var preparing: Set<String> = []
    @ObservationIgnored private var infoCache: [String: PageInfo] = [:]

    init(state: AppState, library: Result<QuranLibrary, QuranStoreError>) {
        self.state = state
        switch library {
        case .success(let value):
            self.library = value
            loadError = nil
            var fonts: [String: PageFontStore] = [:]
            for layout in value.store.layouts {
                fonts[layout.id] = PageFontStore(layout: layout, store: value.store)
            }
            pageFonts = fonts
        case .failure(let error):
            self.library = nil
            loadError = error.description
            pageFonts = [:]
        }
        normalizePosition()
    }

    // MARK: Current position

    var store: QuranStore? { library?.store }

    var layout: LayoutInfo? {
        guard let store else { return nil }
        return (try? store.layout(state.script)) ?? store.layouts.first
    }

    var font: MushafFont? { layout.flatMap { library?.fonts[$0.id] } }

    /// The current layout's page fonts, when it has them.
    var currentPageFonts: PageFontStore? { layout.flatMap { pageFonts[$0.id] } }

    /// Whether the current layout is drawn with its page fonts; otherwise with its single (fallback) font.
    var usesPageFonts: Bool { currentPageFonts?.status == .ready }

    var style: PageStyle { style(usingPageFonts: usesPageFonts) }

    private func style(usingPageFonts: Bool) -> PageStyle {
        var style: PageStyle
        if usingPageFonts, let settings = layout?.pageFonts {
            style = PageStyle(calibration: settings.calibration,
                              lineMetrics: LineMetrics(lineHeight: settings.lineHeight, ascent: settings.ascent))
        } else {
            style = PageStyle(calibration: layout?.calibration ?? 0.04)
        }
        // Calibrations may fit most lines rather than the widest (IndoPak); the rest shrink slightly.
        style.shrinksWideLines = true
        return style
    }

    /// Starts the one-time page font download when the current layout needs it.
    func preparePageFonts() {
        guard let fonts = currentPageFonts, fonts.status == .missing else { return }
        fonts.download()
    }

    var pageNumber: Int {
        guard let layout else { return 1 }
        return min(max(state.pages[layout.id] ?? 1, 1), layout.pageCount)
    }

    var pageInfo: PageInfo? {
        guard let layout, let store else { return nil }
        let key = "\(layout.id):\(pageNumber)"
        if let cached = infoCache[key] { return cached }
        let info = try? store.pageInfo(pageNumber, of: layout)
        infoCache[key] = info
        return info
    }

    /// The surah shown in the header: the selected ayah's when it is on this page, otherwise the page's first.
    var currentSurah: Surah? {
        guard let store, let info = pageInfo else { return nil }
        let number = isOnPage(state.selectedAyah) ? state.selectedAyah.surah : info.firstAyah.surah
        return store.surah(number)
    }

    /// The translation shown under the page.
    var translation: TranslationDatabase? { translations?.current }

    var selectedTranslation: String? { translation?.text(for: state.selectedAyah) }

    func isOnPage(_ ayah: AyahKey) -> Bool {
        guard let info = pageInfo else { return false }
        return info.firstAyah <= ayah && ayah <= info.lastAyah
    }

    // MARK: Page layout

    /// A page (the current one by default) laid out to fit `size`: full width when it fits, otherwise
    /// narrower so the whole page shows.
    func pageLayout(page: Int? = nil, fitting size: CGSize) -> PageLayout? {
        guard let job = layoutJob(page: page ?? pageNumber, fitting: size) else { return nil }
        if let cached = layoutCache[job.key] { return cached }
        let result = job.run()
        remember(result, key: job.key)
        return result
    }

    /// Everything needed to lay out a page, which can run off the main thread.
    private struct LayoutJob: Sendable {
        let key: String
        let page: MushafPage
        let width: Double
        let font: MushafFont
        let style: PageStyle
        let glyphFonts: GlyphFonts?

        func run() -> PageLayout {
            PageLayoutEngine.layout(page, width: width, font: font, style: style, glyphFonts: glyphFonts)
        }
    }

    private func layoutJob(page number: Int, fitting size: CGSize) -> LayoutJob? {
        guard let layout, let font, let store, size.width > 40, size.height > 40, (1 ... layout.pageCount).contains(number) else {
            return nil
        }
        let glyphFonts = usesPageFonts ? currentPageFonts?.glyphFonts(page: number) : nil
        let style = style(usingPageFonts: glyphFonts != nil)
        let width = PageLayoutEngine.width(fitting: size.height, maximumWidth: size.width, linesPerPage: layout.linesPerPage,
                                           font: font, style: style).rounded(.down)
        let key = "\(layout.id):\(glyphFonts == nil ? "f" : "g"):\(number):\(Int(width))"
        let page: MushafPage
        if let cached = pageCache["\(layout.id):\(number)"] {
            page = cached
        } else {
            guard let loaded = try? store.page(number, of: layout) else { return nil }
            page = loaded
            if pageCache.count > 24 { pageCache.removeAll() }
            pageCache["\(layout.id):\(number)"] = loaded
        }
        return LayoutJob(key: key, page: page, width: width, font: font, style: style, glyphFonts: glyphFonts)
    }

    /// A few layouts are kept; each holds its page font, so more would cost memory for little gain.
    private func remember(_ result: PageLayout, key: String) {
        if layoutCache.count >= 8 { layoutCache.removeAll() }
        layoutCache[key] = result
    }

    /// Lays out and draws the next and previous pages off the main thread after a page is shown. Core
    /// Graphics keeps the rendered glyphs, and each page has its own font, so the first draw of a page is
    /// slow (about 14 ms) and later ones fast (under 1 ms); page turns then only draw prepared pages.
    func prepareNeighbours(fitting size: CGSize, scale: CGFloat) {
        let jobs = [pageNumber + 1, pageNumber - 1].compactMap { layoutJob(page: $0, fitting: size) }
            .filter { layoutCache[$0.key] == nil && !preparing.contains($0.key) }
        guard !jobs.isEmpty else { return }
        preparing.formUnion(jobs.map(\.key))
        Task.detached(priority: .utility) { [weak self] in
            for job in jobs {
                let result = job.run()
                Self.warmGlyphs(of: result, scale: scale)
                await MainActor.run {
                    self?.preparing.remove(job.key)
                    self?.remember(result, key: job.key)
                }
            }
        }
    }

    /// Draws a layout into a scratch bitmap at the screen's scale, so its glyphs are rendered and cached.
    nonisolated private static func warmGlyphs(of layout: PageLayout, scale: CGFloat) {
        guard let context = CGContext(data: nil, width: max(Int(layout.size.width * scale), 1), height: max(Int(layout.size.height * scale), 1),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        PageRenderer.draw(layout, in: context)
    }

    /// The page height at a reader width, used to size the popover.
    func pageHeight(width: Double) -> Double {
        guard let layout, let font else { return width * 1.3 }
        return PageLayoutEngine.pageHeight(width: width, linesPerPage: layout.linesPerPage, font: font, style: style)
    }

    // MARK: Navigation

    /// Shows a page of the current layout, remembering which way the reader moved.
    private func show(page: Int, in layout: LayoutInfo) {
        let current = pageNumber
        lastTurn = page == current ? lastTurn : page > current ? 1 : -1
        state.pages[layout.id] = page
    }

    func goToPage(_ number: Int) {
        guard let layout else { return }
        followsPlayback = false
        readingManzil = false
        let page = min(max(number, 1), layout.pageCount)
        show(page: page, in: layout)
        // Keep the selection on screen so the translation strip follows reading.
        if let info = pageInfo, !isOnPage(state.selectedAyah) { state.selectedAyah = info.firstAyah }
    }

    /// Moves forward (+1, the next page) or back (−1) through the mushaf.
    func turnPage(_ direction: Int) {
        // The Manzil scrolls; its pages are not turned.
        guard !readingManzil else { return }
        goToPage(pageNumber + direction)
    }

    func goTo(_ ayah: AyahKey) {
        guard let layout, let store, store.contains(ayah), let page = try? store.firstPage(of: ayah, in: layout) else { return }
        followsPlayback = false
        readingManzil = false
        show(page: page, in: layout)
        state.selectedAyah = ayah
    }

    func goTo(surah: Int) {
        goTo(AyahKey(surah: surah, ayah: 1))
    }

    func goTo(juz: Int) {
        if let ayah = try? store?.firstAyah(ofJuz: juz) { goTo(ayah) }
    }

    func jump(to target: JumpTarget) {
        overlay = nil
        switch target {
        case .ayah(let ayah): goTo(ayah)
        case .page(let page): goToPage(page)
        case .surah(let surah): goTo(surah: surah)
        }
    }

    func select(_ ayah: AyahKey) {
        followsPlayback = false
        state.selectedAyah = ayah
    }

    /// Recitation moved to another ayah: select it and turn to its page, unless the reader has browsed away.
    func followPlayback(to ayah: AyahKey) {
        guard followsPlayback else { return }
        state.selectedAyah = ayah
        guard !isOnPage(ayah), let layout, let page = try? store?.firstPage(of: ayah, in: layout) else { return }
        show(page: page, in: layout)
    }

    /// Selects the next (+1) or previous (−1) ayah, turning the page when it starts elsewhere.
    func selectAdjacentAyah(_ direction: Int) {
        if readingManzil {
            if let next = Manzil.ayah(direction, from: state.selectedAyah) { select(next) }
            return
        }
        guard let store else { return }
        let next = direction > 0 ? store.ayah(after: state.selectedAyah) : store.ayah(before: state.selectedAyah)
        guard let next, let layout, let pages = try? store.pages(containing: next, in: layout), let first = pages.first else { return }
        followsPlayback = false
        state.selectedAyah = next
        if !pages.contains(pageNumber) { show(page: direction > 0 ? first : pages.last ?? first, in: layout) }
    }

    /// "Back to playing": follow the recited ayah again and show it.
    func returnToPlayback(at ayah: AyahKey) {
        followsPlayback = true
        followPlayback(to: ayah)
    }

    // MARK: Playback units

    /// The ayahs that start on a page. An ayah continued from the previous page belongs to that page,
    /// unless it fills this page entirely.
    func ayahsStarting(onPage number: Int) -> ClosedRange<AyahKey>? {
        guard let layout, let store, let info = try? store.pageInfo(number, of: layout) else { return nil }
        var first = info.firstAyah
        if (try? store.firstPage(of: first, in: layout)) != number, let next = store.ayah(after: first), next <= info.lastAyah {
            first = next
        }
        return first ... info.lastAyah
    }

    /// The ayahs of the page where `ayah` starts, which the Loop repeats in page mode.
    func pageRange(of ayah: AyahKey) -> ClosedRange<AyahKey>? {
        guard let layout, let page = try? store?.firstPage(of: ayah, in: layout) else { return nil }
        return ayahsStarting(onPage: page)
    }

    /// The surahs in a juz, in order, with the ayahs of each that fall in it. Worked out once per juz:
    /// the picker shows all thirty, and it should open without querying the database each time.
    func juzContents(_ juz: Int) -> [(surah: Surah, ayahs: ClosedRange<Int>)] {
        if let cached = juzCache[juz] { return cached }
        guard let store, let first = try? store.firstAyah(ofJuz: juz), let last = try? store.lastAyah(ofJuz: juz) else { return [] }
        let contents: [(surah: Surah, ayahs: ClosedRange<Int>)] = (first.surah ... last.surah).compactMap { number in
            guard let surah = store.surah(number) else { return nil }
            let start = number == first.surah ? first.ayah : 1
            let end = number == last.surah ? last.ayah : surah.ayahCount
            return (surah, start ... end)
        }
        juzCache[juz] = contents
        return contents
    }

    // MARK: The Manzil

    /// Shows the Manzil in the main area, scrolling, with the passage holding the selection (or the first).
    func showManzil() {
        overlay = nil
        readingManzil = true
        if Manzil.passage(containing: state.selectedAyah) == nil { state.selectedAyah = Manzil.passages[0].lowerBound }
    }

    /// Back to the mushaf, at the selected ayah's page.
    func closeManzil() {
        readingManzil = false
        if let layout, let page = try? store?.firstPage(of: state.selectedAyah, in: layout) { show(page: page, in: layout) }
    }

    /// A Manzil passage set in justified lines at `width`, in the current script's font (its Unicode text,
    /// unmodified), at the same size as the mushaf page.
    func manzilLayout(passage index: Int, width: Double) -> PageLayout? {
        guard let layout, let font, let store, width > 40, Manzil.passages.indices.contains(index) else { return nil }
        let key = "\(layout.id):\(index):\(Int(width))"
        if let cached = manzilLayouts[key] { return cached }
        let range = Manzil.passages[index]
        let ayahs = (range.lowerBound.ayah ... range.upperBound.ayah).map { AyahKey(surah: range.lowerBound.surah, ayah: $0) }
        let words = ayahs.map { (ayah: $0, words: (try? store.words(of: $0, in: layout)) ?? []) }
        let result = PageLayoutEngine.flow(words, width: width, font: font, style: style(usingPageFonts: false))
        if manzilLayouts.count > 60 { manzilLayouts.removeAll() }
        manzilLayouts[key] = result
        return result
    }

    /// The surahs with ayahs in a juz, which downloading the juz fetches.
    func surahs(inJuz juz: Int) -> [Int] {
        juzContents(juz).map(\.surah.number)
    }

    /// The last ayah of the page or juz `ayah` is in, where "Stop playback at" ends playback.
    func unitEnd(of ayah: AyahKey, _ stop: PlaybackStop) -> AyahKey? {
        switch stop {
        case .page: pageRange(of: ayah)?.upperBound
        case .juz: (try? store?.juz(of: ayah)).flatMap { try? store?.lastAyah(ofJuz: $0) }
        case .surah, .quran: nil
        }
    }

    /// Where the player's outer skip buttons go from `ayah`. Forward (+1): the next surah or page.
    /// Back (−1): the start of the current surah or page, or the previous one when already at its start.
    func skipTarget(from ayah: AyahKey, direction: Int, unit: SkipUnit) -> AyahKey? {
        // In the Manzil, the outer buttons move by passage.
        if readingManzil || state.loopMode == .manzil {
            guard let index = Manzil.passage(containing: ayah) else { return Manzil.passages[0].lowerBound }
            if direction > 0 { return Manzil.passages.indices.contains(index + 1) ? Manzil.passages[index + 1].lowerBound : nil }
            if ayah > Manzil.passages[index].lowerBound { return Manzil.passages[index].lowerBound }
            return index > 0 ? Manzil.passages[index - 1].lowerBound : nil
        }
        switch unit {
        case .surah:
            if direction > 0 { return ayah.surah < 114 ? AyahKey(surah: ayah.surah + 1, ayah: 1) : nil }
            if ayah.ayah > 1 { return AyahKey(surah: ayah.surah, ayah: 1) }
            return ayah.surah > 1 ? AyahKey(surah: ayah.surah - 1, ayah: 1) : nil
        case .page:
            guard let layout, let store, var page = try? store.firstPage(of: ayah, in: layout) else { return nil }
            if direction < 0, let start = ayahsStarting(onPage: page)?.lowerBound, start < ayah { return start }
            page += direction
            while (1 ... layout.pageCount).contains(page) {
                if let start = ayahsStarting(onPage: page)?.lowerBound, direction > 0 ? start > ayah : start < ayah { return start }
                page += direction
            }
            return nil
        }
    }

    /// Switches script, staying on the selected ayah when it is visible, otherwise on the page's first ayah.
    func switchScript(to id: String) {
        guard id != state.script, let store, let target = try? store.layout(id) else { return }
        let anchor = isOnPage(state.selectedAyah) ? state.selectedAyah : (pageInfo?.firstAyah ?? state.selectedAyah)
        state.script = id
        lastTurn = 0
        if let page = try? store.firstPage(of: anchor, in: target) { state.pages[id] = page }
    }

    // MARK: Range loops

    /// "Loop from Here", then "Loop to Here" on another ayah (either order) starts the loop.
    func loopFromHere(_ ayah: AyahKey) {
        state.loopRangeStart = ayah
    }

    func loopToHere(_ ayah: AyahKey) {
        guard let start = state.loopRangeStart else { return }
        state.loopRangeStart = nil
        loopAyahs?(min(start, ayah) ... max(start, ayah))
    }

    // MARK: Copying

    /// Copies the ayah's source text unchanged, with its reference and optionally its translation.
    func copy(_ ayah: AyahKey, withTranslation: Bool) {
        guard let store, let layout, let text = try? store.text(of: ayah, in: layout) else { return }
        var string = "\(text)\n(Quran \(ayah))"
        if withTranslation, let translation, let meaning = translation.text(for: ayah) {
            string += "\n\n\(meaning) (\(translation.info.name), \(translation.info.source) v\(translation.info.version))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func normalizePosition() {
        guard let store, let layout else { return }
        if !store.contains(state.selectedAyah) { state.selectedAyah = AyahKey(surah: 1, ayah: 1) }
        if state.pages[layout.id] == nil, let page = try? store.firstPage(of: state.selectedAyah, in: layout) {
            state.pages[layout.id] = page
        }
        if state.script != layout.id { state.script = layout.id }
    }
}

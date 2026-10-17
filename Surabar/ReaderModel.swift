import AppKit
import MushafRendering
import Observation
import QuranStore

/// Reading state and navigation shared by every reader surface. Positions are kept as ayahs;
/// page numbers are only ever looked up for the current layout.
@MainActor
@Observable
final class ReaderModel {
    enum Overlay: Equatable {
        case surahPicker
        case jump
    }

    let state: AppState
    let library: QuranLibrary?
    let loadError: String?
    var overlay: Overlay?
    /// Whether the page and selection follow the recited ayah. Turning pages, jumping, or selecting
    /// another ayah stops following until playback is moved or "Back to playing" is chosen.
    var followsPlayback = true
    /// Starts recitation at an ayah (the page's "Play from Here"); set by the app.
    @ObservationIgnored var playAyah: ((AyahKey) -> Void)?
    /// Downloadable page fonts by layout id, for layouts drawn with one font per page.
    let pageFonts: [String: PageFontStore]

    @ObservationIgnored private var pageCache: [String: MushafPage] = [:]
    @ObservationIgnored private var layoutCache: [String: PageLayout] = [:]
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

    var selectedTranslation: String? { library?.translation?.text(for: state.selectedAyah) }

    func isOnPage(_ ayah: AyahKey) -> Bool {
        guard let info = pageInfo else { return false }
        return info.firstAyah <= ayah && ayah <= info.lastAyah
    }

    // MARK: Page layout

    /// The page laid out to fit `size`: full width when it fits, otherwise narrower so the whole page shows.
    func pageLayout(fitting size: CGSize) -> PageLayout? {
        guard let layout, let font, let store, size.width > 40, size.height > 40 else { return nil }
        let glyphFonts = usesPageFonts ? currentPageFonts?.glyphFonts(page: pageNumber) : nil
        let style = style(usingPageFonts: glyphFonts != nil)
        let width = PageLayoutEngine.width(fitting: size.height, maximumWidth: size.width, linesPerPage: layout.linesPerPage,
                                           font: font, style: style).rounded(.down)
        let key = "\(layout.id):\(glyphFonts == nil ? "f" : "g"):\(pageNumber):\(Int(width))"
        if let cached = layoutCache[key] { return cached }
        let page: MushafPage
        if let cached = pageCache["\(layout.id):\(pageNumber)"] {
            page = cached
        } else {
            guard let loaded = try? store.page(pageNumber, of: layout) else { return nil }
            page = loaded
            pageCache["\(layout.id):\(pageNumber)"] = loaded
        }
        let result = PageLayoutEngine.layout(page, width: width, font: font, style: style, glyphFonts: glyphFonts)
        if layoutCache.count > 24 { layoutCache.removeAll() }
        if pageCache.count > 24 { pageCache.removeAll() }
        layoutCache[key] = result
        return result
    }

    /// The page height at a reader width, used to size the popover.
    func pageHeight(width: Double) -> Double {
        guard let layout, let font else { return width * 1.3 }
        return PageLayoutEngine.pageHeight(width: width, linesPerPage: layout.linesPerPage, font: font, style: style)
    }

    // MARK: Navigation

    func goToPage(_ number: Int) {
        guard let layout else { return }
        followsPlayback = false
        let page = min(max(number, 1), layout.pageCount)
        state.pages[layout.id] = page
        // Keep the selection on screen so the translation strip follows reading.
        if let info = pageInfo, !isOnPage(state.selectedAyah) { state.selectedAyah = info.firstAyah }
    }

    /// Moves forward (+1, the next page) or back (−1) through the mushaf.
    func turnPage(_ direction: Int) {
        goToPage(pageNumber + direction)
    }

    func goTo(_ ayah: AyahKey) {
        guard let layout, let store, store.contains(ayah), let page = try? store.firstPage(of: ayah, in: layout) else { return }
        followsPlayback = false
        state.pages[layout.id] = page
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
        state.pages[layout.id] = page
    }

    /// Selects the next (+1) or previous (−1) ayah, turning the page when it starts elsewhere.
    func selectAdjacentAyah(_ direction: Int) {
        guard let store else { return }
        let next = direction > 0 ? store.ayah(after: state.selectedAyah) : store.ayah(before: state.selectedAyah)
        guard let next, let layout, let pages = try? store.pages(containing: next, in: layout), let first = pages.first else { return }
        followsPlayback = false
        state.selectedAyah = next
        if !pages.contains(pageNumber) { state.pages[layout.id] = direction > 0 ? first : pages.last ?? first }
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

    /// The surahs with ayahs in a juz, which downloading the juz fetches.
    func surahs(inJuz juz: Int) -> [Int] {
        guard let store, let first = try? store.firstAyah(ofJuz: juz), let last = try? store.lastAyah(ofJuz: juz) else { return [] }
        return Array(first.surah ... last.surah)
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
        if let page = try? store.firstPage(of: anchor, in: target) { state.pages[id] = page }
    }

    // MARK: Copying

    /// Copies the ayah's source text unchanged, with its reference and optionally its translation.
    func copy(_ ayah: AyahKey, withTranslation: Bool) {
        guard let store, let layout, let text = try? store.text(of: ayah, in: layout) else { return }
        var string = "\(text)\n(Quran \(ayah))"
        if withTranslation, let translation = library?.translation, let english = translation.text(for: ayah) {
            string += "\n\n\(english) (\(translation.name))"
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

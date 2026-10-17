import Annotations
import AppKit
import MushafRendering
import SwiftUI

/// What a page view draws: a mushaf page, or one of the Manzil's passages set in justified lines.
enum PageContent: Hashable {
    case page(Int)
    case manzil(Int)
}

/// SwiftUI wrapper for the Core Text page view.
struct MushafPageView: NSViewRepresentable {
    let model: ReaderModel
    /// What this view draws; a page turn creates a new view, so the old page slides out unchanged.
    let content: PageContent
    let theme: ReaderTheme
    let accent: NSColor

    func makeNSView(context: Context) -> MushafPageNSView {
        MushafPageNSView(model: model, content: content)
    }

    func updateNSView(_ view: MushafPageNSView, context: Context) {
        // Reading these registers SwiftUI observation, so the view redraws when they change.
        view.update(content: content, script: model.state.script, selection: model.state.selectedAyah, theme: theme,
                    accent: accent, pageFonts: model.usesPageFonts,
                    marks: (model.annotations?.highlights, model.annotations?.notes.count))
    }
}

/// Draws a mushaf page, maps clicks to ayahs, and exposes each ayah fragment to accessibility.
final class MushafPageNSView: NSView {
    private let model: ReaderModel
    private var theme: ReaderTheme = .system
    private var accent: NSColor = .controlAccentColor
    private var pageLayout: PageLayout?
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false

    private var content: PageContent

    init(model: ReaderModel, content: PageContent) {
        self.model = model
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(content: PageContent, script: String, selection: AyahKey, theme: ReaderTheme, accent: NSColor, pageFonts: Bool,
                marks: (highlights: [AyahKey: HighlightEntry]?, notes: Int?)) {
        // A new selection or highlight cross-fades in rather than jumping.
        let marksChanged = drawnSelection != nil && (drawnSelection != selection || drawnHighlights != marks.highlights?.count)
        drawnSelection = selection
        drawnHighlights = marks.highlights?.count
        self.content = content
        self.theme = theme
        self.accent = accent
        relayout()
        switch content {
        case .page(let page): setAccessibilityLabel("Mushaf page \(page)")
        case .manzil(let passage): setAccessibilityLabel("Manzil passage \(passage + 1)")
        }
        if marksChanged, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            layer.add(fade, forKey: "marks")
        }
        needsDisplay = true
    }

    private var drawnSelection: AyahKey?
    private var drawnHighlights: Int?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        pageLayout = switch content {
        case .page(let page): model.pageLayout(page: page, fitting: bounds.size)
        case .manzil(let passage): model.manzilLayout(passage: passage, width: bounds.width)
        }
        needsDisplay = true
    }

    /// Where the page sits in the view: centred horizontally and vertically.
    private var pageOrigin: CGPoint {
        guard let pageLayout else { return .zero }
        return CGPoint(x: ((bounds.width - pageLayout.size.width) / 2).rounded(),
                       y: ((bounds.height - pageLayout.size.height) / 2).rounded())
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = pageColors()
        context.setFillColor(colors.background)
        context.fill(bounds)
        guard let pageLayout else { return }
        context.saveGState()
        context.translateBy(x: pageOrigin.x, y: pageOrigin.y)
        // A highlighted selection is outlined, so the highlight keeps its colour.
        let selection = model.state.selectedAyah
        var decorations = decorations(for: pageLayout)
        let highlightedSelection = model.annotations?.highlights[selection] != nil
        if highlightedSelection {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                decorations.outlines.append(.init(rects: pageLayout.rects(for: selection), color: accent.withAlphaComponent(0.85).cgColor))
            }
        }
        PageRenderer.draw(pageLayout, in: context, colors: colors, highlighted: highlightedSelection ? [] : pageLayout.rects(for: selection),
                          decorations: decorations)
        let size = bounds.size, scale = window?.backingScaleFactor ?? 2
        // Once this page is on screen, get the pages either side ready.
        DispatchQueue.main.async { [model, content] in
            if content == .page(model.pageNumber) { model.prepareNeighbours(fitting: size, scale: scale) }
        }
        context.restoreGState()
    }

    /// Highlights as fills behind their ayahs, and a dot above the number of each ayah with a note.
    private func decorations(for pageLayout: PageLayout) -> PageDecorations {
        guard let annotations = model.annotations else { return .none }
        var decorations = PageDecorations()
        let ayahs = Set(pageLayout.items.compactMap(\.item.ayah))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for ayah in ayahs.sorted() {
                if let highlight = annotations.highlights[ayah] {
                    decorations.fills.append(.init(rects: pageLayout.rects(for: ayah), color: highlight.color.color.cgColor))
                }
                if annotations.notes[ayah] != nil, let point = pageLayout.markerPoint(for: ayah) {
                    decorations.dots.append(.init(center: point, color: accent.cgColor))
                }
            }
        }
        return decorations
    }

    private func pageColors() -> PageColors {
        if theme == .sepia {
            return PageColors(background: CGColor(red: 0.973, green: 0.941, blue: 0.871, alpha: 1),
                              text: CGColor(red: 0.18, green: 0.141, blue: 0.086, alpha: 1),
                              highlight: accent.withAlphaComponent(0.16).cgColor)
        }
        var colors = PageColors.light
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = PageColors(background: NSColor.textBackgroundColor.cgColor, text: NSColor.labelColor.cgColor,
                                highlight: accent.withAlphaComponent(0.2).cgColor)
        }
        return colors
    }

    // MARK: Interaction

    /// The ayah under a point in view coordinates.
    private func ayah(at point: NSPoint) -> AyahKey? {
        guard let pageLayout else { return nil }
        let pagePoint = CGPoint(x: point.x - pageOrigin.x, y: pageLayout.size.height - (point.y - pageOrigin.y))
        return pageLayout.item(at: pagePoint)?.item.ayah
    }

    override func mouseDown(with event: NSEvent) {
        if let ayah = ayah(at: convert(event.locationInWindow, from: nil)) { model.select(ayah) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ayah = ayah(at: convert(event.locationInWindow, from: nil)) else { return nil }
        model.select(ayah)
        let menu = NSMenu()
        menu.addItem(withTitle: "Ayah \(ayah)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        if model.playAyah != nil {
            add("Play from Here", to: menu, ayah) { $0.playAyah?($1) }
            if let start = model.state.loopRangeStart, start != ayah {
                add("Loop \((min(start, ayah) ... max(start, ayah)).title)", to: menu, ayah) { $0.loopToHere($1) }
                add("Cancel Loop from \(start)", to: menu, ayah) { model, _ in model.state.loopRangeStart = nil }
            } else {
                add("Loop from Here", to: menu, ayah) { $0.loopFromHere($1) }
            }
            menu.addItem(.separator())
        }
        if let annotations = model.annotations {
            add(annotations.isBookmarked(ayah) ? "Remove Bookmark" : "Bookmark", key: "b", to: menu, ayah) {
                $0.annotations?.toggleBookmark($1)
            }
            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            let colors = NSMenu()
            for color in HighlightColor.allCases {
                let item = add(color.title, to: colors, ayah) { $0.annotations?.setHighlight($1, color) }
                item.image = swatch(color.swatch)
                item.state = annotations.highlights[ayah]?.color == color ? .on : .off
            }
            if annotations.highlights[ayah] != nil {
                colors.addItem(.separator())
                add("Remove Highlight", to: colors, ayah) { $0.annotations?.setHighlight($1, nil) }
            }
            highlight.submenu = colors
            menu.addItem(highlight)
            add(annotations.notes[ayah] == nil ? "Add Note…" : "Edit Note…", to: menu, ayah) { $0.overlay = .note($1) }
            menu.addItem(.separator())
        }
        add("Copy Ayah", key: "c", to: menu, ayah) { $0.copy($1, withTranslation: false) }
        add("Copy with Translation", to: menu, ayah) { $0.copy($1, withTranslation: true) }.isEnabled = model.translation != nil
        return menu
    }

    /// Adds a menu item that runs `action` with the model and the ayah.
    @discardableResult
    private func add(_ title: String, key: String = "", to menu: NSMenu, _ ayah: AyahKey,
                     _ action: @escaping @MainActor (ReaderModel, AyahKey) -> Void) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: #selector(runAyahAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key == "c" ? .command : []
        item.target = self
        item.representedObject = AyahAction(ayah: ayah, action: action)
        return item
    }

    @objc private func runAyahAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AyahAction else { return }
        action.action(model, action.ayah)
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Two-finger horizontal swipes turn pages. Pages advance leftwards (right to left), so moving
    /// the content to the right shows the next page.
    override func scrollWheel(with event: NSEvent) {
        // The Manzil's passages scroll in their scroll view; only mushaf pages turn.
        guard case .page = content, event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return super.scrollWheel(with: event) }
        if event.phase == .began || event.phase == .mayBegin {
            swipeDistance = 0
            swipeHandled = false
        }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeDistance != 0 else { return }
        swipeDistance += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        if !swipeHandled, abs(swipeDistance) > 70 {
            swipeHandled = true
            model.turnPage(swipeDistance > 0 ? 1 : -1)
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let pageLayout else { return nil }
        let origin = pageOrigin
        var elements: [NSAccessibilityElement] = []
        var seen = Set<AyahKey>()
        for item in pageLayout.items {
            guard let ayah = item.item.ayah, seen.insert(ayah).inserted else { continue }
            let fragments = pageLayout.items.filter { $0.item.ayah == ayah }
            let union = pageLayout.rects(for: ayah).reduce(CGRect.null) { $0.union($1) }
            let rect = NSRect(x: union.minX + origin.x, y: origin.y + pageLayout.size.height - union.maxY,
                              width: union.width, height: union.height)
            let element = NSAccessibilityElement.element(
                withRole: .staticText, frame: NSAccessibility.screenRect(fromView: self, rect: rect),
                label: accessibilityLabel(for: ayah), parent: self)
            element.setAccessibilityValue(fragments.map(\.item.text).joined(separator: " "))
            element.setAccessibilitySelected(ayah == model.state.selectedAyah)
            element.setAccessibilityCustomActions(accessibilityActions(for: ayah))
            elements.append(element)
        }
        return elements
    }

    /// "Ayah 2:255, bookmarked, yellow highlight, has a note".
    private func accessibilityLabel(for ayah: AyahKey) -> String {
        var parts = ["Ayah \(ayah.description)"]
        if let annotations = model.annotations {
            if annotations.isBookmarked(ayah) { parts.append("bookmarked") }
            if let highlight = annotations.highlights[ayah] { parts.append("\(highlight.color.rawValue) highlight") }
            if annotations.notes[ayah] != nil { parts.append("has a note") }
        }
        return parts.joined(separator: ", ")
    }

    /// The ayah menu's main actions, for VoiceOver (VO-Command-Space).
    private func accessibilityActions(for ayah: AyahKey) -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        let model = model
        if model.playAyah != nil {
            actions.append(NSAccessibilityCustomAction(name: "Play from here") { MainActor.assumeIsolated { model.playAyah?(ayah) }; return true })
        }
        if let annotations = model.annotations {
            let bookmarked = annotations.isBookmarked(ayah)
            actions.append(NSAccessibilityCustomAction(name: bookmarked ? "Remove bookmark" : "Bookmark") {
                MainActor.assumeIsolated { model.annotations?.toggleBookmark(ayah) }
                return true
            })
            actions.append(NSAccessibilityCustomAction(name: annotations.notes[ayah] == nil ? "Add note" : "Edit note") {
                MainActor.assumeIsolated {
                    model.select(ayah)
                    model.overlay = .note(ayah)
                }
                return true
            })
        }
        actions.append(NSAccessibilityCustomAction(name: "Copy ayah") {
            MainActor.assumeIsolated { model.copy(ayah, withTranslation: false) }
            return true
        })
        return actions
    }
}

/// A context-menu action for one ayah.
private final class AyahAction {
    let ayah: AyahKey
    let action: @MainActor (ReaderModel, AyahKey) -> Void

    init(ayah: AyahKey, action: @escaping @MainActor (ReaderModel, AyahKey) -> Void) {
        self.ayah = ayah
        self.action = action
    }
}

private extension NSAccessibilityElement {
    static func element(withRole role: NSAccessibility.Role, frame: NSRect, label: String, parent: Any) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(role)
        element.setAccessibilityFrame(frame)
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(parent)
        return element
    }
}

import AppKit
import MushafRendering
import SwiftUI

/// SwiftUI wrapper for the Core Text page view.
struct MushafPageView: NSViewRepresentable {
    let model: ReaderModel
    let theme: ReaderTheme
    let accent: NSColor

    func makeNSView(context: Context) -> MushafPageNSView {
        MushafPageNSView(model: model)
    }

    func updateNSView(_ view: MushafPageNSView, context: Context) {
        // Reading these registers SwiftUI observation, so the view redraws when they change.
        view.update(page: model.pageNumber, script: model.state.script, selection: model.state.selectedAyah, theme: theme,
                    accent: accent, pageFonts: model.usesPageFonts)
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

    init(model: ReaderModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(page: Int, script: String, selection: AyahKey, theme: ReaderTheme, accent: NSColor, pageFonts: Bool) {
        self.theme = theme
        self.accent = accent
        relayout()
        setAccessibilityLabel("Mushaf page \(page)")
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        pageLayout = model.pageLayout(fitting: bounds.size)
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
        PageRenderer.draw(pageLayout, in: context, colors: colors, highlighted: pageLayout.rects(for: model.state.selectedAyah))
        context.restoreGState()
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
        let copy = menu.addItem(withTitle: "Copy Ayah", action: #selector(copyAyah(_:)), keyEquivalent: "c")
        copy.target = self
        copy.representedObject = ayah.description
        let withTranslation = menu.addItem(withTitle: "Copy with Translation", action: #selector(copyWithTranslation(_:)),
                                           keyEquivalent: "")
        withTranslation.target = self
        withTranslation.representedObject = ayah.description
        withTranslation.isEnabled = model.library?.translation != nil
        return menu
    }

    @objc private func copyAyah(_ sender: NSMenuItem) {
        if let ayah = (sender.representedObject as? String).flatMap(AyahKey.init(string:)) { model.copy(ayah, withTranslation: false) }
    }

    @objc private func copyWithTranslation(_ sender: NSMenuItem) {
        if let ayah = (sender.representedObject as? String).flatMap(AyahKey.init(string:)) { model.copy(ayah, withTranslation: true) }
    }

    /// Two-finger horizontal swipes turn pages. Pages advance leftwards (right to left), so moving
    /// the content to the right shows the next page.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return super.scrollWheel(with: event) }
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
                label: "Ayah \(ayah)", parent: self)
            element.setAccessibilityValue(fragments.map(\.item.text).joined(separator: " "))
            element.setAccessibilitySelected(ayah == model.state.selectedAyah)
            elements.append(element)
        }
        return elements
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

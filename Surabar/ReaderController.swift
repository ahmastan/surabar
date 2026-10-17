import AppKit
import MushafRendering
import SwiftUI

/// Shows the reader either in a popover under the status item or in a floating window.
@MainActor
final class ReaderController: NSObject {
    private let state: AppState
    private let model: ReaderModel
    private let player: RecitationPlayer?
    private let showSettings: () -> Void
    private let popover = NSPopover()
    private var panel: NSPanel?
    private weak var anchor: NSStatusBarButton?

    private static let frameName = "SurabarReaderWindow"

    init(state: AppState, model: ReaderModel, player: RecitationPlayer?, showSettings: @escaping () -> Void) {
        self.state = state
        self.model = model
        self.player = player
        self.showSettings = showSettings
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = makeHost()
        observeState()
    }

    var isPopoverShown: Bool { popover.isShown }
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Whether a key-down event belongs to the reader (popover or detached window).
    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window == panel || window == popover.contentViewController?.view.window
    }

    // MARK: Showing and hiding

    func toggle(from button: NSStatusBarButton) {
        anchor = button
        if state.isDetached {
            if let panel, panel.isVisible, panel.isKeyWindow { panel.orderOut(nil) } else { showPanel() }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(from: button)
        }
    }

    func open(from button: NSStatusBarButton) {
        anchor = button
        if state.isDetached { showPanel() } else if !popover.isShown { showPopover(from: button) }
    }

    func close() {
        popover.performClose(nil)
        panel?.orderOut(nil)
    }

    func detach() {
        popover.performClose(nil)
        state.isDetached = true
        showPanel()
    }

    func attach() {
        panel?.orderOut(nil)
        state.isDetached = false
        if let anchor { showPopover(from: anchor) }
    }

    private func showPopover(from button: NSStatusBarButton) {
        resizePopover(for: button)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyWindowSettings()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Sizing and appearance

    private func resizePopover(for button: NSStatusBarButton?) {
        let screen = button?.window?.screen ?? NSScreen.main
        let available = screen.map { Double($0.visibleFrame.height) } ?? 900
        let width = state.size.width
        popover.contentSize = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: width),
                                                       showTranslation: state.showTranslation, availableHeight: available)
    }

    private func applyWindowSettings() {
        let appearance = Self.appearance(for: state.theme)
        popover.appearance = appearance
        if popover.isShown { resizePopover(for: anchor) }
        guard let panel else { return }
        panel.appearance = appearance
        panel.level = state.keepOnTop ? .floating : .normal
        panel.isFloatingPanel = state.keepOnTop
        if !panel.isVisible { return }
        // Choosing a size in the menu or Settings resizes the detached window to that width.
        var frame = panel.frame
        let target = state.size.width
        if abs(panel.contentLayoutRect.width - target) > 0.5, lastAppliedSize != state.size {
            let delta = target - panel.contentLayoutRect.width
            frame.size.width += delta
            panel.setFrame(frame, display: true, animate: true)
        }
        lastAppliedSize = state.size
    }

    private var lastAppliedSize: ReaderSize?

    private static func appearance(for theme: ReaderTheme) -> NSAppearance? {
        switch theme {
        case .system: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Re-applies window settings whenever the observed state changes.
    private func observeState() {
        withObservationTracking {
            // Page fonts change the page's height once they are downloaded.
            _ = (state.size, state.theme, state.keepOnTop, state.showTranslation, state.script, model.usesPageFonts)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyWindowSettings()
                self?.observeState()
            }
        }
    }

    // MARK: Construction

    private func makeHost() -> NSHostingController<ReaderView> {
        let actions = ReaderActions(
            detach: { [weak self] in self?.detach() },
            attach: { [weak self] in self?.attach() },
            openSettings: { [weak self] in self?.showSettings() }
        )
        let host = NSHostingController(rootView: ReaderView(state: state, model: model, player: player, actions: actions))
        // The popover and window set the size; the SwiftUI content fills it.
        host.sizingOptions = []
        return host
    }

    private func makePanel() -> NSPanel {
        let width = state.size.width
        let height = ReaderLayout.preferredHeight(pageHeight: model.pageHeight(width: width), showTranslation: state.showTranslation)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Surabar"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = makeHost()
        panel.contentMinSize = NSSize(width: ReaderLayout.minimumWidth, height: ReaderLayout.minimumHeight)
        panel.contentMaxSize = NSSize(width: ReaderLayout.maximumWidth, height: CGFloat.greatestFiniteMagnitude)
        panel.delegate = self
        lastAppliedSize = state.size
        if !panel.setFrameUsingName(Self.frameName) || !Self.isOnScreen(panel.frame) {
            placeNearStatusItem(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private func placeNearStatusItem(_ panel: NSPanel) {
        guard let screen = anchor?.window?.screen ?? NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.height = min(frame.height, visible.height - ReaderLayout.screenMargin)
        let anchorX = anchor?.window?.frame.midX ?? visible.maxX - frame.width / 2
        frame.origin.x = min(max(anchorX - frame.width / 2, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = visible.maxY - frame.height - 8
        panel.setFrame(frame, display: false)
    }

    /// A remembered frame can point at a display that is no longer connected.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 80 && $0.visibleFrame.intersection(frame).height >= 40 }
    }
}

extension ReaderController: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        applyWindowSettings()
    }
}

extension ReaderController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        lastAppliedSize = state.size
    }
}

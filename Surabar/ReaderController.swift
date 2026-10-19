import Annotations
import AppKit
import MushafRendering
import SwiftUI

/// Shows the reader either in a popover under the status item or in a floating window.
@MainActor
final class ReaderController: NSObject {
    private let state: AppState
    private let model: ReaderModel
    private let player: RecitationPlayer?
    private let downloads: DownloadCenter?
    private let popover = NSPopover()
    private var panel: NSPanel?
    /// The detached window's content, inside its backdrop.
    private var panelHost: NSHostingController<ReaderView>?
    private var appliedBackdrop: Bool?
    private weak var anchor: NSStatusBarButton?

    private static let frameName = "SurabarReaderWindow"

    init(state: AppState, model: ReaderModel, player: RecitationPlayer?, downloads: DownloadCenter?) {
        self.state = state
        self.model = model
        self.player = player
        self.downloads = downloads
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = makeHost()
        observeState()
    }

    var isPopoverShown: Bool { popover.isShown }
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Whether a sleep timer is set (the menu bar icon takes the accent color meanwhile).
    var sleepTimerIsSet: Bool { player?.sleepTimer != nil }

    /// The status item menu's recitation item: pause what's playing, or continue a paused recitation
    /// (also the one remembered from the last session), showing its page.
    var recitationMenuAction: (title: String, perform: @MainActor () -> Void)? {
        guard let player else { return nil }
        if player.isActive { return ("Pause Recitation", { player.pause() }) }
        guard let ayah = player.resumableAyah else { return nil }
        let name = model.store?.surah(ayah.surah)?.nameSimple ?? ""
        return ("Continue \(name) \(ayah.description)", { [weak self] in
            self?.model.returnToPlayback(at: ayah)
            player.resume()
        })
    }

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
            closePopover()
        } else {
            showPopover(from: button)
        }
    }

    func open(from button: NSStatusBarButton) {
        anchor = button
        if state.isDetached { showPanel() } else if !popover.isShown { showPopover(from: button) }
    }

    /// Opens the reader with Settings shown in place.
    func showSettings(from button: NSStatusBarButton?) {
        model.overlay = nil
        state.isShowingSettings = true
        if let button { open(from: button) }
    }

    func close() {
        closePopover()
        panel?.orderOut(nil)
    }

    func detach() {
        closePopover()
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
        // Opened from the global shortcut, Surabar is not the active app yet: show the popover once the
        // activation request has been handled, and give it keyboard focus.
        DispatchQueue.main.async { [self] in
            guard !popover.isShown else { return }
            openedAt = CACurrentMediaTime()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// When the popover last opened, to ignore a stray close in the moment after (see `popoverShouldClose`).
    private var openedAt = 0.0
    /// Set while Surabar itself closes the popover (Esc, the shortcut, the menu bar icon, detaching).
    private var closingOnPurpose = false

    private func closePopover() {
        closingOnPurpose = true
        popover.performClose(nil)
        closingOnPurpose = false
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyWindowSettings()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Sizing and appearance

    /// The measured Settings height while they are shown, or nil for the reader.
    private var settingsContentHeight: Double? {
        state.isShowingSettings ? state.settingsContentHeights[state.settingsTab] : nil
    }

    /// Settings are shown but not yet measured: keep the current size until they are, so the
    /// window animates once, straight to the right height.
    private var awaitingSettingsHeight: Bool {
        state.isShowingSettings && settingsContentHeight == nil
    }

    private func resizePopover(for button: NSStatusBarButton?) {
        if awaitingSettingsHeight { return }
        let screen = button?.window?.screen ?? NSScreen.main
        let available = screen.map { Double($0.visibleFrame.height) } ?? 900
        let width = state.size.width
        popover.contentSize = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: ReaderLayout.pageWidth(width)),
                                                       showTranslation: state.showTranslation, availableHeight: available,
                                                       mode: state.viewMode, settingsContentHeight: settingsContentHeight)
    }

    private func applyWindowSettings() {
        let appearance = Self.appearance(for: state.theme)
        popover.appearance = appearance
        if popover.isShown { resizePopover(for: anchor) }
        guard let panel else { return }
        panel.appearance = appearance
        panel.level = state.keepOnTop ? .floating : .normal
        applyBackdrop(to: panel)
        panel.isFloatingPanel = state.keepOnTop
        fitPanelToContent(panel)
        if !panel.isVisible { return }
        // Choosing a size in the menu or Settings resizes the detached window to that width, and to the
        // page's height at it.
        if lastAppliedSize != state.size, abs(panel.contentLayoutRect.width - state.size.width) > 0.5 {
            var content = NSSize(width: state.size.width, height: panel.contentLayoutRect.height)
            if showsPage { content.height = pageFittedHeight(width: content.width) }
            setContentSize(content, of: panel)
        }
        lastAppliedSize = state.size
    }

    /// Whether the detached window shows the mushaf page (not Settings or "Player only").
    private var showsPage: Bool {
        state.viewMode == .quranAndPlayer && !state.isShowingSettings
    }

    /// The window height at which the page fills `width` with only its small side margins.
    private func pageFittedHeight(width: Double) -> Double {
        ReaderLayout.preferredHeight(pageHeight: model.pageHeight(width: ReaderLayout.pageWidth(width)), showTranslation: state.showTranslation)
    }

    /// Sets the content size, keeping the top edge in place, within the visible screen.
    private func setContentSize(_ size: NSSize, of panel: NSPanel) {
        let titlebar = panel.frame.height - panel.contentLayoutRect.height
        var frame = panel.frame
        frame.origin.y = frame.maxY - (size.height + titlebar)
        frame.size = NSSize(width: size.width, height: size.height + titlebar)
        if let visible = panel.screen?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = max(frame.origin.y, visible.minY)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private var lastAppliedSize: ReaderSize?

    /// What the panel last showed: the mode, and the Settings height while they were open.
    private var panelContent: PanelContent?
    /// The panel's height in "Quran + player" mode, restored when it returns from Settings or "Player only".
    private var readerHeight: CGFloat?

    private struct PanelContent: Equatable {
        let mode: ReaderViewMode
        let settingsHeight: CGFloat?

        var isReader: Bool { mode == .quranAndPlayer && settingsHeight == nil }
    }

    /// Resizes the detached window when its content changes: Settings and "Player only" have a fixed
    /// height that fits their content, and the reader returns to the height it had before.
    private func fitPanelToContent(_ panel: NSPanel) {
        if awaitingSettingsHeight { return }
        let content = PanelContent(mode: state.viewMode, settingsHeight: settingsContentHeight.map {
            CGFloat(ReaderLayout.settingsHeight(content: $0))
        })
        let fixed = content.settingsHeight ?? (content.mode == .playerOnly ? ReaderLayout.playerOnlyHeight : nil)
        panel.contentMinSize = NSSize(width: ReaderLayout.minimumWidth, height: fixed ?? ReaderLayout.minimumHeight)
        panel.contentMaxSize = NSSize(width: ReaderLayout.maximumWidth, height: fixed ?? CGFloat.greatestFiniteMagnitude)
        guard let previous = panelContent, previous != content else {
            panelContent = content
            return
        }
        panelContent = content
        let current = panel.contentLayoutRect.height
        if previous.isReader { readerHeight = current }
        setContentHeight(fixed ?? readerHeight ?? max(current, ReaderLayout.minimumHeight), of: panel)
    }

    /// Changes the height keeping the top edge in place, within the visible screen.
    private func setContentHeight(_ height: CGFloat, of panel: NSPanel) {
        var frame = panel.frame
        let delta = height - panel.contentLayoutRect.height
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        if let visible = panel.screen?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

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
            _ = (state.size, state.theme, state.keepOnTop, state.showTranslation, state.script, model.usesPageFonts,
                 state.viewMode, state.isShowingSettings, state.settingsTab, state.settingsContentHeights, state.showsDownloads,
                 state.showsAcknowledgements, state.glassStyle)
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
            editCustomAccent: { [weak self] in self?.editCustomAccent() },
            exportAnnotations: { [weak self] in self?.exportAnnotations() },
            importAnnotations: { [weak self] in self?.importAnnotations() }
        )
        let host = NSHostingController(rootView: ReaderView(state: state, model: model, player: player, downloads: downloads, actions: actions))
        // The popover and window set the size; the SwiftUI content fills it.
        host.sizingOptions = []
        return host
    }

    private func makePanel() -> NSPanel {
        let width = state.size.width
        let height = ReaderLayout.preferredHeight(pageHeight: model.pageHeight(width: ReaderLayout.pageWidth(width)), showTranslation: state.showTranslation)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Surabar"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panelHost = makeHost()
        applyBackdrop(to: panel)
        panel.delegate = self
        lastAppliedSize = state.size
        if !panel.setFrameUsingName(Self.frameName) || !Self.isOnScreen(panel.frame) {
            placeNearStatusItem(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        // The saved frame may come from the other mode.
        if state.viewMode == .playerOnly {
            setContentHeight(ReaderLayout.playerOnlyHeight, of: panel)
        } else if panel.contentLayoutRect.height < ReaderLayout.minimumHeight {
            setContentHeight(height, of: panel)
        }
        panelContent = PanelContent(mode: state.viewMode, settingsHeight: nil)
        fitPanelToContent(panel)
        return panel
    }

    /// The detached window's backdrop: Apple's glass view (`NSGlassEffectView`) for Liquid Glass, or a
    /// standard frosted material. The window itself is transparent around it.
    private func applyBackdrop(to panel: NSPanel) {
        guard let host = panelHost else { return }
        let glass = state.glassStyle.usesGlass
        guard appliedBackdrop != glass else { return }
        appliedBackdrop = glass
        host.view.removeFromSuperview()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        if #available(macOS 26.0, *), glass {
            let backdrop = NSGlassEffectView()
            backdrop.style = .regular
            backdrop.cornerRadius = Self.windowCornerRadius
            backdrop.contentView = host.view
            panel.contentView = backdrop
        } else {
            let backdrop = NSVisualEffectView()
            backdrop.material = .popover
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            host.view.frame = backdrop.bounds
            host.view.autoresizingMask = [.width, .height]
            backdrop.addSubview(host.view)
            panel.contentView = backdrop
        }
    }

    /// The corner radius of macOS 26 titled windows, so the glass meets the window's edge.
    private static let windowCornerRadius = 16.0

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

    /// A transient popover closes when something outside it is used. Opened from the global shortcut,
    /// the activation that follows could close it at once, so closes Surabar did not ask for are ignored
    /// for a moment after it opens.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let justOpened = CACurrentMediaTime() - openedAt < 0.3
        #if DEBUG
        print("Surabar: popover close requested (\(closingOnPurpose ? "by Surabar" : "by the system")"
              + "\(justOpened ? ", just opened" : ""); app active: \(NSApp.isActive))")
        #endif
        return closingOnPurpose || !justOpened
    }

    /// The reader always reopens on the mushaf rather than in Settings.
    func popoverDidClose(_ notification: Notification) {
        state.isShowingSettings = false
        model.overlay = nil
    }
}

extension ReaderController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        lastAppliedSize = state.size
    }

    func windowWillClose(_ notification: Notification) {
        state.isShowingSettings = false
    }
}

// MARK: Custom accent colour

extension ReaderController {
    /// Opens the system colour panel for the custom accent. A transient popover would close as soon as
    /// the panel takes focus, so the popover stays open until the colour panel closes.
    func editCustomAccent() {
        let colorPanel = NSColorPanel.shared
        colorPanel.showsAlpha = false
        colorPanel.isContinuous = true
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(customAccentChanged(_:)))
        let accent = state.customAccent
        colorPanel.color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        popover.behavior = .applicationDefined
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: colorPanel)
        colorPanel.orderFront(nil)
    }

    @objc private func customAccentChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        state.customAccent = AccentRGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        state.accent = .custom
    }

    @objc private func colorPanelWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        popover.behavior = .transient
    }
}

// MARK: Annotation backups

extension ReaderController {
    /// Runs a file panel; the popover stays open meanwhile (a transient one closes when the panel appears).
    private func withFilePanel(_ body: () -> Void) {
        popover.behavior = .applicationDefined
        body()
        popover.behavior = .transient
    }

    func exportAnnotations() {
        guard let annotations = model.annotations else { return }
        withFilePanel {
            let panel = NSSavePanel()
            panel.title = "Export Bookmarks, Highlights, and Notes"
            panel.nameFieldStringValue = "Surabar Annotations \(Date().formatted(.iso8601.year().month().day())).json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try annotations.backup.encoded().write(to: url, options: .atomic)
                state.backupMessage = "Exported to \(url.lastPathComponent)."
            } catch {
                state.backupMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    func importAnnotations() {
        guard let annotations = model.annotations, let store = model.store else { return }
        withFilePanel {
            let panel = NSOpenPanel()
            panel.title = "Import Bookmarks, Highlights, and Notes"
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let backup = try AnnotationBackup.decode(Data(contentsOf: url), ayahCounts: store.surahs.map(\.ayahCount))
                let result = try annotations.importBackup(backup)
                state.backupMessage = result.applied == 0 && result.skipped == 0
                    ? "The backup was empty."
                    : "Imported \(result.applied) \(result.applied == 1 ? "entry" : "entries")"
                        + (result.skipped > 0 ? "; kept \(result.skipped) newer \(result.skipped == 1 ? "one" : "ones") already here." : ".")
            } catch let error as AnnotationBackup.ValidationError {
                state.backupMessage = "\(error.description). Nothing was changed."
            } catch {
                state.backupMessage = "Couldn't import: \(error.localizedDescription). Nothing was changed."
            }
        }
    }
}

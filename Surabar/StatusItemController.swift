import AppKit
import MushafRendering

/// The menu bar icon: left-click toggles the reader, right-click (or Control-click) shows the app menu.
@MainActor
final class StatusItemController: NSObject {
    private let state: AppState
    private let reader: ReaderController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(state: AppState, reader: ReaderController) {
        self.state = state
        self.reader = reader
        super.init()
        guard let button = item.button else { return }
        showIcon()
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    var button: NSStatusBarButton? { item.button }

    /// Shows the icon chosen in Settings › Appearance, and again whenever it changes. While a sleep timer is
    /// set, the icon takes the accent color (Sepia's brown belongs to the reader, so the menu bar uses the
    /// ordinary accent).
    private func showIcon() {
        guard let button = item.button else { return }
        let (image, sleeping, tint) = withObservationTracking {
            (state.menuBarIcon.image, reader.sleepTimerIsSet, ReaderPalette.color(for: state.accent, custom: state.customAccent))
        } onChange: { [weak self] in
            Task { @MainActor in self?.showIcon() }
        }
        // The menu bar draws template images in its own black or white, so the coloured icon is its own image.
        button.image = sleeping ? image.map { $0.tinted(tint) } : image
        button.toolTip = sleeping ? "Surabar · sleep timer on" : "Surabar"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(from: sender)
        } else {
            reader.toggle(from: sender)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        if let recitation = reader.recitationMenuAction {
            menu.addItem(action(recitation.title, perform: recitation.perform))
            menu.addItem(.separator())
        }
        menu.addItem(action("Open Surabar") { [weak self] in self?.reader.open(from: button) })
        if state.isDetached {
            menu.addItem(action("Attach to Menu Bar") { [weak self] in self?.reader.attach() })
        } else {
            menu.addItem(action("Detach Window") { [weak self] in self?.reader.detach() })
        }
        menu.addItem(.separator())
        for size in ReaderSize.allCases {
            let entry = action(size.title, key: size.shortcut) { [weak self] in self?.state.size = size }
            entry.state = state.size == size ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(action("Settings…", key: ",", modifiers: .command) { [weak self] in self?.reader.showSettings(from: button) })
        menu.addItem(action("Check for Updates…") { Updater.shared.checkForUpdates() })
        menu.addItem(.separator())
        menu.addItem(action("Quit Surabar", key: "q", modifiers: .command) { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                        perform: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = MenuAction(perform)
        return item
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }
}

/// Holds a menu item's closure, so each entry does not need its own selector.
private final class MenuAction {
    let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }
}

extension NSImage {
    /// A copy filled with `color` (drawn when shown, so a system color follows the appearance), not a template.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { [self] rect in
            draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

extension MenuBarIcon {
    /// A template image, so macOS tints it for light and dark menu bars.
    var image: NSImage? {
        let image = assetName.flatMap { NSImage(named: $0) } ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Surabar"
        return image
    }
}

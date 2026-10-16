import AppKit
import MushafRendering

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var settings: SettingsWindowController!
    private var reader: ReaderController!
    private var statusItem: StatusItemController!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsWindowController(state: state)
        reader = ReaderController(state: state) { [weak self] in self?.settings.show() }
        statusItem = StatusItemController(state: state, reader: reader) { [weak self] in self?.settings.show() }
        // Local event monitors are called on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        // Running from Xcode opens the reader straight away, which makes development faster.
        if ProcessInfo.processInfo.environment["SURABAR_OPEN_ON_LAUNCH"] == "1", let button = statusItem.button {
            DispatchQueue.main.async { self.reader.open(from: button) }
        }
    }

    /// Reader keyboard shortcuts: 1, 2, 3 choose a size; Escape closes; Command-comma opens Settings.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard reader.owns(event.window) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "," {
            settings.show()
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        if event.keyCode == 53 {  // Escape
            reader.close()
            return true
        }
        if let size = ReaderSize.allCases.first(where: { $0.shortcut == event.charactersIgnoringModifiers }) {
            state.size = size
            return true
        }
        return false
    }
}

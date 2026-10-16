import AppKit
import MushafRendering

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var model: ReaderModel!
    private var settings: SettingsWindowController!
    private var reader: ReaderController!
    private var statusItem: StatusItemController!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshot.runIfRequested() { return }
        #endif
        model = ReaderModel(state: state, library: QuranLibrary.loadBundled())
        settings = SettingsWindowController(state: state, model: model)
        reader = ReaderController(state: state, model: model) { [weak self] in self?.settings.show() }
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

    /// Reader keyboard shortcuts. Arrows follow the mushaf's right-to-left order: ← is the next page,
    /// Option-← the next ayah. 1, 2, 3 choose a size; ⌘F or ⌘L jumps; ⌘C copies the selected ayah;
    /// Escape closes an open panel, then the reader. Space and B arrive with recitation and bookmarks.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard reader.owns(event.window) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // While typing in a search or jump field, only Escape is handled here.
        let typing = event.window?.firstResponder is NSText
        if event.keyCode == 53 {  // Escape
            if model.overlay != nil { model.overlay = nil } else { reader.close() }
            return true
        }
        if modifiers == .command {
            switch key {
            case ",": settings.show()
            case "f", "l": model.overlay = .jump
            case "c" where !typing: model.copy(state.selectedAyah, withTranslation: false)
            default: return false
            }
            return true
        }
        guard !typing, model.library != nil || !(123 ... 124).contains(event.keyCode) else { return false }
        switch (event.keyCode, modifiers) {
        case (123, []): model.turnPage(1)
        case (124, []): model.turnPage(-1)
        case (123, [.option]): model.selectAdjacentAyah(1)
        case (124, [.option]): model.selectAdjacentAyah(-1)
        default:
            guard modifiers.isEmpty, let size = ReaderSize.allCases.first(where: { $0.shortcut == key }) else { return false }
            state.size = size
        }
        return true
    }
}

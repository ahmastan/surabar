import AppKit
import MushafRendering
import Recitation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var model: ReaderModel!
    private var player: RecitationPlayer?
    private var reader: ReaderController!
    private var statusItem: StatusItemController!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshot.runIfRequested() || DebugPlaybackProbe.runIfRequested() { return }
        #endif
        model = ReaderModel(state: state, library: QuranLibrary.loadBundled())
        if let store = model.store {
            let player = RecitationPlayer(state: state, ayahCounts: store.surahs.map(\.ayahCount),
                                          reciters: ReciterCatalogLoader.bundled())
            player.onAyahChange = { [weak self] ayah in self?.model.followPlayback(to: ayah) }
            player.onUserAction = { [weak self] in self?.model.followsPlayback = true }
            player.pageRange = { [weak self] ayah in self?.model.pageRange(of: ayah) }
            model.playAyah = { [weak player] ayah in player?.play(from: ayah) }
            self.player = player
        }
        reader = ReaderController(state: state, model: model, player: player)
        statusItem = StatusItemController(state: state, reader: reader)
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
    /// Option-← the next ayah (the recited one while playing), Command-← the next surah or page for
    /// recitation. R cycles the Loop. 1, 2, 3 choose a size; ⌘F or ⌘L jumps; ⌘C copies the selected ayah;
    /// Escape closes Settings or an open panel, then the reader. Space plays or pauses. B arrives with bookmarks.
    /// While Settings are shown, other keys go to the settings controls.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard reader.owns(event.window) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // While typing in a search or jump field, only Escape is handled here.
        let typing = event.window?.firstResponder is NSText
        if event.keyCode == 53 {  // Escape
            if state.isShowingSettings {
                state.isShowingSettings = false
            } else if model.overlay != nil {
                model.overlay = nil
            } else {
                reader.close()
            }
            return true
        }
        if modifiers == .command, (123 ... 124).contains(event.keyCode), !typing, !state.isShowingSettings, let player {
            let from = player.ayah ?? state.selectedAyah
            if let target = model.skipTarget(from: from, direction: event.keyCode == 123 ? 1 : -1, unit: state.skipUnit) {
                player.skip(to: target)
            }
            return true
        }
        if modifiers == .command {
            switch key {
            case ",": reader.showSettings(from: nil)
            case "f", "l":
                state.isShowingSettings = false
                model.overlay = .jump
            case "c" where !typing: model.copy(state.selectedAyah, withTranslation: false)
            default: return false
            }
            return true
        }
        guard !typing, !state.isShowingSettings, model.library != nil || !(123 ... 124).contains(event.keyCode) else { return false }
        switch (event.keyCode, modifiers) {
        case (49, []):  // Space
            guard let player else { return false }
            player.togglePlayPause(startingAt: state.selectedAyah)
        case (123, []): model.turnPage(1)
        case (124, []): model.turnPage(-1)
        case (123, [.option]), (124, [.option]):
            let direction = event.keyCode == 123 ? 1 : -1
            if let player, player.isActive {
                player.stepAyah(direction, from: state.selectedAyah)
            } else {
                model.selectAdjacentAyah(direction)
            }
        case (15, []):  // R
            guard let player else { return false }
            player.cycleLoop()
        default:
            guard modifiers.isEmpty, let size = ReaderSize.allCases.first(where: { $0.shortcut == key }) else { return false }
            state.size = size
        }
        return true
    }
}

#if DEBUG
import AppKit
import MushafRendering
import SwiftUI

/// Debug builds only: renders the reader offscreen to a PNG and quits, for visual checks without a display capture.
///
///     SURABAR_SNAPSHOT=/tmp/reader.png SURABAR_SNAPSHOT_STATE="script=indopak ayah=2:255 size=L theme=dark overlay=jump" \
///       Surabar.app/Contents/MacOS/Surabar
///
/// Uses its own settings domain, so the user's reading position and preferences are untouched.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SURABAR_SNAPSHOT"] else { return false }
        let suite = "io.github.ahmastan.surabar.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        let model = ReaderModel(state: state, library: QuranLibrary.loadBundled())
        var overlay: ReaderModel.Overlay?
        for pair in (environment["SURABAR_SNAPSHOT_STATE"] ?? "").split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "script": model.switchScript(to: parts[1])
            case "ayah": AyahKey(string: parts[1]).map(model.goTo)
            case "page": Int(parts[1]).map(model.goToPage)
            case "size": ReaderSize(rawValue: parts[1]).map { state.size = $0 }
            case "theme": ReaderTheme(rawValue: parts[1]).map { state.theme = $0 }
            case "translation": state.showTranslation = parts[1] != "off"
            case "overlay": overlay = parts[1] == "jump" ? .jump : .surahPicker
            default: break
            }
        }
        model.overlay = overlay
        let width = state.size.width
        let size = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: width),
                                            showTranslation: state.showTranslation, availableHeight: 2000)
        let actions = ReaderActions(detach: {}, attach: {}, openSettings: {})
        let view = NSHostingView(rootView: ReaderView(state: state, model: model, actions: actions))
        view.frame = CGRect(origin: .zero, size: size)
        switch state.theme {
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        case .light, .sepia, .system: view.appearance = NSAppearance(named: .aqua)
        }
        // Scroll views only lay out their content in a window that is on screen, so show it far off screen.
        let window = NSWindow(contentRect: view.frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        // Let SwiftUI finish a layout pass before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])
            do { try data?.write(to: URL(fileURLWithPath: path)) } catch { exit(1) }
            exit(0)
        }
        return true
    }
}
#endif

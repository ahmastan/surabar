#if DEBUG
import AVFoundation
import AppKit
import MushafRendering
import SwiftUI

/// Debug builds only: renders the reader offscreen to a PNG and quits, for visual checks without a display capture.
///
///     SURABAR_SNAPSHOT=/tmp/reader.png SURABAR_SNAPSHOT_STATE="script=indopak ayah=2:255 size=L theme=dark overlay=jump" \
///       Surabar.app/Contents/MacOS/Surabar
///
/// Also: `loop=off|ayah|unit`, `count=3`, `skip=page|surah`, `mode=player`, `settings=appearance|reading|player|general`, `accent=red` or `accent=#2E8B7A`.
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
            case "loop": LoopMode(rawValue: parts[1]).map { state.loopMode = $0 }
            case "count": Int(parts[1]).map { state.repeatCount = $0 }
            case "skip": SkipUnit(rawValue: parts[1]).map { state.skipUnit = $0 }
            case "mode": state.viewMode = parts[1] == "player" ? .playerOnly : .quranAndPlayer
            case "downloads":
                state.isShowingSettings = true
                state.settingsTab = .player
                state.showsDownloads = true
            case "settings":
                state.isShowingSettings = true
                SettingsTab(rawValue: parts[1]).map { state.settingsTab = $0 }
            case "accent":
                if let rgb = AccentRGB(hex: parts[1]) {
                    state.customAccent = rgb
                    state.accent = .custom
                } else {
                    ReaderAccent(rawValue: parts[1]).map { state.accent = $0 }
                }
            default: break
            }
        }
        model.overlay = overlay
        let width = state.size.width
        let size = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: width),
                                            showTranslation: state.showTranslation, availableHeight: 2000,
                                            mode: state.viewMode)
        let actions = ReaderActions(detach: {}, attach: {}, editCustomAccent: {})
        let player = model.store.map { store in
            RecitationPlayer(state: state, ayahCounts: store.surahs.map(\.ayahCount), reciters: ReciterCatalogLoader.bundled(),
                             timings: TimingsStore(ayahCounts: store.surahs.map(\.ayahCount)), audio: AudioCache())
        }
        let downloads = player.map { _ in
            DownloadCenter(audio: AudioCache(), timings: TimingsStore(ayahCounts: model.store!.surahs.map(\.ayahCount)), state: state)
        }
        let view = NSHostingView(rootView: ReaderView(state: state, model: model, player: player, downloads: downloads, actions: actions))
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
            // Settings are sized to their measured content, as in the app.
            if state.isShowingSettings, let content = state.settingsContentHeights[state.settingsTab] {
                view.setFrameSize(CGSize(width: size.width, height: ReaderLayout.settingsHeight(content: content)))
                view.layoutSubtreeIfNeeded()
            }
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

/// Debug builds only: plays recitation muted from an ayah and prints each ayah change with the
/// recording's position, and whether the audio continued or jumped (a seek or a new recording).
///
///     SURABAR_PROBE_PLAYBACK="1:1 25" [SURABAR_PROBE_RECITER=3] [SURABAR_PROBE_LOOP="ayah 2"] Surabar.app/Contents/MacOS/Surabar
@MainActor
enum DebugPlaybackProbe {
    static func runIfRequested() -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["SURABAR_PROBE_PLAYBACK"] else { return false }
        let parts = spec.split(separator: " ")
        guard let ayah = parts.first.flatMap({ AyahKey(string: String($0)) }), let seconds = parts.dropFirst().first.flatMap({ Double($0) }),
              case .success(let library) = QuranLibrary.loadBundled() else { exit(2) }
        let suite = "io.github.ahmastan.surabar.probe"
        UserDefaults().removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        if let reciter = ProcessInfo.processInfo.environment["SURABAR_PROBE_RECITER"].flatMap(Int.init) { state.reciterID = reciter }
        // SURABAR_PROBE_STOP=page|surah|juz|quran
        if let stop = ProcessInfo.processInfo.environment["SURABAR_PROBE_STOP"].flatMap(PlaybackStop.init(rawValue:)) {
            state.playbackStop = stop
        }
        // SURABAR_PROBE_LOOP="ayah 2" or "unit 0" (the surah; 0 repeats until stopped).
        if let loop = ProcessInfo.processInfo.environment["SURABAR_PROBE_LOOP"]?.split(separator: " "), loop.count == 2,
           let mode = LoopMode(rawValue: String(loop[0])), let count = Int(loop[1]) {
            state.loopMode = mode
            state.repeatCount = count
            state.repeatPause = 1
        }
        let counts = library.store.surahs.map(\.ayahCount)
        // SURABAR_PROBE_AUDIO_DIR keeps the probe's saved audio out of the app's cache.
        let audio = ProcessInfo.processInfo.environment["SURABAR_PROBE_AUDIO_DIR"].map { AudioCache(root: URL(fileURLWithPath: $0)) } ?? AudioCache()
        let player = RecitationPlayer(state: state, ayahCounts: counts, reciters: ReciterCatalogLoader.bundled(),
                                      timings: TimingsStore(ayahCounts: counts), audio: audio)
        let queue = player.debugQueuePlayer
        queue.isMuted = true
        let origin = CACurrentMediaTime()
        var last: (wall: Double, position: Double, item: ObjectIdentifier?)?
        player.onAyahChange = { ayah in
            let wall = CACurrentMediaTime() - origin
            let position = queue.currentTime().seconds
            let item = queue.currentItem.map(ObjectIdentifier.init)
            var how = "start"
            if let last {
                let expected = last.position + (wall - last.wall) * Double(queue.rate == 0 ? 1 : queue.rate)
                how = last.item == item && abs(position - expected) < 0.3 ? "continued (no seek)" : "jumped"
            }
            print(String(format: "%6.2fs  %@%@  at %.2fs in %@ — %@", wall, ayah.description,
                         player.step.map { $0.repetition > 1 ? " #\($0.repetition)" : "" } ?? "", position,
                         (queue.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "-", how))
        }
        // Sample continuously so each ayah change is compared with where the audio just was.
        queue.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            MainActor.assumeIsolated {
                guard queue.rate != 0, time.seconds.isFinite else { return }
                last = (CACurrentMediaTime() - origin, time.seconds, queue.currentItem.map(ObjectIdentifier.init))
            }
        }
        player.play(from: ayah)
        print("playing reciter \(state.reciterID) from \(ayah) for \(Int(seconds)) s (muted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print(String(format: "status: %@, at %@, %.1f s into %@", "\(player.status)", player.ayah?.description ?? "-",
                         queue.currentTime().seconds, (queue.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "-"))
            exit(0)
        }
        return true
    }
}
#endif


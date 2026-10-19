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
        model.translations = TranslationLibrary(state: state, folder: FileManager.default.temporaryDirectory.appending(path: "surabar-snapshot-translations"))
        var overlay: ReaderModel.Overlay?
        var expandedJuz: Set<Int>?
        var available = 2000.0
        var sleep: RecitationPlayer.SleepTimer?
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
            case "overlay":
                overlay = switch parts[1] {
                case "jump": .jump
                case "annotations": .annotations
                case "juz": .surahPicker
                case "note": .note(model.state.selectedAyah)
                default: .surahPicker
                }
            case "annotations":
                // Sample annotations in memory: a bookmark, highlights, and a note around 2:255.
                let store = try? AnnotationStore(inMemory: true)
                store?.setBookmark(AyahKey(surah: 2, ayah: 255), label: "Ayat al-Kursi")
                store?.setHighlight(AyahKey(surah: 2, ayah: 255), .yellow)
                store?.setHighlight(AyahKey(surah: 2, ayah: 256), .green)
                store?.setNote(AyahKey(surah: 2, ayah: 257), "Light and darkness; memorise with 2:255.")
                store?.setNote(AyahKey(surah: 2, ayah: 255), "Recite after every prayer.")
                model.annotations = store
            case "range":
                state.loopRange = ClosedRange<AyahKey>(stored: parts[1])
                state.loopMode = .range
            case "glass": GlassStyle(rawValue: parts[1]).map { state.glassStyle = $0 }
            case "screen": Double(parts[1]).map { available = $0 }
            case "manzilday": state.manzilRoutine.setRead(true, on: Date())
            // continue=18:45: a recitation remembered from the last session, paused there (the Continue pill).
            case "continue": AyahKey(string: parts[1]).map { state.lastPlayedAyah = $0 }
            // sleep=30 (minutes) or sleep=page|surah|juz: a sleep timer is set.
            case "sleep": sleep = Int(parts[1]).map { .after(Double($0 * 60)) } ?? PlaybackStop(rawValue: parts[1]).map { .endOf($0) }
            case "expand": expandedJuz = Set(parts[1].split(separator: ",").compactMap { Int($0) })
            case "loop": LoopMode(rawValue: parts[1]).map { state.loopMode = $0 }
            case "count": Int(parts[1]).map { state.repeatCount = $0 }
            case "skip": SkipUnit(rawValue: parts[1]).map { state.skipUnit = $0 }
            case "mode": state.viewMode = parts[1] == "player" ? .playerOnly : .quranAndPlayer
            case "translations":
                state.isShowingSettings = true
                state.settingsTab = .reading
                state.showsTranslations = true
            case "acknowledgements":
                state.isShowingSettings = true
                state.settingsTab = .general
                state.showsAcknowledgements = true
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
        if environment["SURABAR_SNAPSHOT_STATE"]?.contains("overlay=manzil") == true {
            model.overlay = nil
            model.showManzil()
        }
        let width = state.size.width
        let size = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: ReaderLayout.pageWidth(width)),
                                            showTranslation: state.showTranslation, availableHeight: available,
                                            mode: state.viewMode)
        let actions = ReaderActions(detach: {}, attach: {}, editCustomAccent: {}, exportAnnotations: {}, importAnnotations: {})
        let player = model.store.map { store in
            RecitationPlayer(state: state, ayahCounts: store.surahs.map(\.ayahCount), reciters: ReciterCatalogLoader.bundled(),
                             timings: TimingsStore(ayahCounts: store.surahs.map(\.ayahCount)), audio: AudioCache())
        }
        let downloads = player.map { _ in
            DownloadCenter(audio: AudioCache(), timings: TimingsStore(ayahCounts: model.store!.surahs.map(\.ayahCount)), state: state)
        }
        player?.readsManzil = { model.readingManzil }
        if let sleep { player?.setSleepTimer(sleep) }
        var reader = ReaderView(state: state, model: model, player: player, downloads: downloads, actions: actions)
        reader.debugExpandedJuz = expandedJuz
        let view = NSHostingView(rootView: reader)
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
            if ProcessInfo.processInfo.environment["SURABAR_SNAPSHOT_DEBUG"] != nil {
                print("measured settings content:", state.settingsContentHeights.map { "\($0.key.rawValue)=\($0.value)" })
            }
            // Settings are sized to their measured content, as in the app.
            if state.isShowingSettings, let content = state.settingsContentHeights[state.settingsTab] {
                view.setFrameSize(CGSize(width: size.width, height: min(ReaderLayout.settingsHeight(content: content), available - ReaderLayout.screenMargin)))
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
        // SURABAR_PROBE_SLEEP=<seconds>|page|surah|juz: a sleep timer, set when playback starts. Logs the fade
        // (the player's volume; muting doesn't change it) and when playback pauses.
        if let sleep = ProcessInfo.processInfo.environment["SURABAR_PROBE_SLEEP"] {
            let timer: RecitationPlayer.SleepTimer? = Double(sleep).map { .after($0) } ?? PlaybackStop(rawValue: sleep).map { .endOf($0) }
            if let timer { DispatchQueue.main.async { player.setSleepTimer(timer) } }
            var lastVolume = queue.volume, lastStatus = player.status
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let wall = CACurrentMediaTime() - origin
                    if abs(queue.volume - lastVolume) > 0.05 { print(String(format: "%6.2fs  [sleep] volume %.2f", wall, queue.volume)); lastVolume = queue.volume }
                    if player.status != lastStatus {
                        print(String(format: "%6.2fs  [sleep] status %@, timer %@", wall, "\(player.status)", player.sleepTimer == nil ? "cleared" : "set"))
                        lastStatus = player.status
                    }
                }
            }
        }
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
        // SURABAR_PROBE_UI=1: a hidden reader opens and closes the surah picker every 2 s meanwhile, and
        // every stall, rate change, or ayah change is logged, with how long the main thread was blocked.
        if ProcessInfo.processInfo.environment["SURABAR_PROBE_UI"] != nil {
            let model = ReaderModel(state: state, library: .success(library))
            model.annotations = try? AnnotationStore(inMemory: true)
            player.onAyahChange = { [onAyahChange = player.onAyahChange] ayah in onAyahChange?(ayah); model.followPlayback(to: ayah) }
            let actions = ReaderActions(detach: {}, attach: {}, editCustomAccent: {}, exportAnnotations: {}, importAnnotations: {})
            let view = NSHostingView(rootView: ReaderView(state: state, model: model, player: player, downloads: nil, actions: actions))
            view.frame = CGRect(x: 0, y: 0, width: 440, height: 900)
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 900), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            var juz = false
            // SURABAR_PROBE_UI=static: the reader stays as it is (no picker toggling).
            let toggles = ProcessInfo.processInfo.environment["SURABAR_PROBE_UI"] != "static"
            Timer.scheduledTimer(withTimeInterval: 2, repeats: toggles) { _ in
                guard toggles else { return }
                MainActor.assumeIsolated {
                    let start = CACurrentMediaTime()
                    if model.overlay == nil {
                        model.overlay = .surahPicker
                        juz.toggle()
                    } else {
                        model.overlay = nil
                    }
                    view.layoutSubtreeIfNeeded()
                    view.display()
                    print(String(format: "  [ui] picker %@ (main thread busy %.0f ms)", model.overlay == nil ? "closed" : "opened",
                                 (CACurrentMediaTime() - start) * 1000))
                }
            }
            NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { _ in
                print("  [audio] STALLED")
            }
            var lastControl = queue.timeControlStatus
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if queue.timeControlStatus != lastControl {
                        print("  [audio] timeControlStatus \(lastControl.rawValue) -> \(queue.timeControlStatus.rawValue) (reason: \(queue.reasonForWaitingToPlay?.rawValue ?? "-"))")
                        lastControl = queue.timeControlStatus
                    }
                }
            }
        }
        // SURABAR_PROBE_MANZIL=1: Play Manzil from the probe's ayah (which must be in the Manzil).
        // SURABAR_PROBE_AFTER_MANZIL=1: Play Manzil, then 4 s later play the probe's ayah, as playing a surah does.
        if ProcessInfo.processInfo.environment["SURABAR_PROBE_AFTER_MANZIL"] != nil {
            player.playManzil()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("  [probe] playing \(ayah) after the Manzil; loop mode: \(state.loopMode.rawValue)")
                player.play(from: ayah)
                print("  [probe] loop mode now: \(state.loopMode.rawValue)")
            }
        } else if ProcessInfo.processInfo.environment["SURABAR_PROBE_MANZIL"] != nil {
            player.onManzilFinished = { print("  [manzil] finished: Read today set") }
            player.playManzil(from: ayah)
        } else {
            player.play(from: ayah)
        }
        print("playing reciter \(state.reciterID) from \(ayah) for \(Int(seconds)) s (muted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print(String(format: "status: %@, at %@, %.1f s into %@", "\(player.status)", player.ayah?.description ?? "-",
                         queue.currentTime().seconds, (queue.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "-"))
            exit(0)
        }
        return true
    }
}
/// Debug builds only: measures the Phase 8 performance targets and prints a report.
///
///     SURABAR_BENCHMARK=1 Surabar.app/Contents/MacOS/Surabar
///
/// Build with optimisation for representative numbers:
/// `xcodebuild … -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O build`.
@MainActor
enum DebugBenchmark {
    /// Memory in MB: the physical footprint (what Activity Monitor shows as Memory) and resident size
    /// (which also counts shared system framework pages).
    static func memory() -> (footprint: Double, resident: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
    }

    static func residentMB() -> Double { memory().footprint }

    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["SURABAR_BENCHMARK"] != nil else { return false }
        var stages: [String] = [String(format: "launch %.0f", residentMB())]
        let suite = "io.github.ahmastan.surabar.benchmark"
        UserDefaults().removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        let model = ReaderModel(state: state, library: QuranLibrary.loadBundled())
        model.translations = TranslationLibrary(state: state, folder: FileManager.default.temporaryDirectory.appending(path: "surabar-bench"))
        model.annotations = try? AnnotationStore(inMemory: true)
        let width = state.size.width
        let size = ReaderLayout.popoverSize(width: width, pageHeight: model.pageHeight(width: ReaderLayout.pageWidth(width)), showTranslation: true,
                                            availableHeight: 1000)
        let player = model.store.map { store in
            RecitationPlayer(state: state, ayahCounts: store.surahs.map(\.ayahCount), reciters: ReciterCatalogLoader.bundled(),
                             timings: TimingsStore(ayahCounts: store.surahs.map(\.ayahCount)),
                             audio: AudioCache(root: FileManager.default.temporaryDirectory.appending(path: "surabar-bench-audio")))
        }
        let actions = ReaderActions(detach: {}, attach: {}, editCustomAccent: {}, exportAnnotations: {}, importAnnotations: {})
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFrontRegardless()

        /// The reader's content appearing: a new hosting view laid out and drawn, as when the popover opens.
        func openReader() -> Double {
            let start = CACurrentMediaTime()
            let view = NSHostingView(rootView: ReaderView(state: state, model: model, player: player, downloads: nil, actions: actions))
            view.frame = CGRect(origin: .zero, size: size)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.display()
            return (CACurrentMediaTime() - start) * 1000
        }
        stages.append(String(format: "data loaded %.0f", residentMB()))
        /// The surah picker appearing (surahs, then juz), as when its button is clicked.
        func openPicker(juz: Bool) -> Double {
            let start = CACurrentMediaTime()
            var picker = SurahPicker(model: model, palette: ReaderPalette(state: state), downloads: nil, reciter: nil)
            // The picker opens over a window that is key, as in the app, so the search field takes focus.
            window.makeKey()
            if juz { picker.debugExpandedJuz = [] }
            let view = NSHostingView(rootView: picker.frame(width: size.width, height: 600))
            view.frame = CGRect(x: 0, y: 0, width: size.width, height: 600)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            view.layoutSubtreeIfNeeded()
            view.display()
            return (CACurrentMediaTime() - start) * 1000
        }
        let pickers = (surahs: (0 ..< 3).map { _ in openPicker(juz: false) }, juz: (0 ..< 3).map { _ in openPicker(juz: true) })
        let cold = openReader()
        stages.append(String(format: "reader shown %.0f", residentMB()))
        let warm = (0 ..< 5).map { _ in openReader() }
        stages.append(String(format: "reader reopened 5× %.0f", residentMB()))

        /// A page turn: the new page laid out (with its page font) and drawn, at the reader's size.
        let pageSize = CGSize(width: width, height: model.pageHeight(width: width))
        let context = CGContext(data: nil, width: Int(pageSize.width * 2), height: Int(pageSize.height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        var turns: [Double] = []
        var parts: [(font: Double, layout: Double, draw: Double)] = []
        var redraws: [Double] = []
        model.goToPage(1)
        for _ in 0 ..< 120 {
            // Each turn is its own event in the app, which drains the autorelease pool.
            let elapsed = autoreleasepool {
                let start = CACurrentMediaTime()
                model.turnPage(1)
                _ = model.currentPageFonts?.glyphFonts(page: model.pageNumber)
                let fonts = CACurrentMediaTime()
                let layout = model.pageLayout(fitting: pageSize)
                let laidOut = CACurrentMediaTime()
                if let layout { PageRenderer.draw(layout, in: context) }
                let end = CACurrentMediaTime()
                if let layout { PageRenderer.draw(layout, in: context) }
                redraws.append((CACurrentMediaTime() - end) * 1000)
                parts.append(((fonts - start) * 1000, (laidOut - fonts) * 1000, (end - laidOut) * 1000))
                return (end - start) * 1000
            }
            turns.append(elapsed)
            model.prepareNeighbours(fitting: pageSize, scale: 2)
            if turns.count % 40 == 0 { stages.append(String(format: "%d pages %.0f", turns.count, residentMB())) }
            // Reading pace: neighbouring page fonts load in the background meanwhile.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var value = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &value, &size, nil, 0)
            return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let sortedTurns = turns.sorted()
        print("hardware: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("page fonts: \(model.usesPageFonts ? "QCF V2 (downloaded)" : "fallback font")")
        print(String(format: "surah picker open: %@ ms; juz list: %@ ms", pickers.surahs.map { String(format: "%.0f", $0) }.joined(separator: ", "),
                     pickers.juz.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        print(String(format: "reader open: cold %.1f ms, warm median %.1f ms (max %.1f)", cold, percentile(warm, 0.5), warm.max() ?? 0))
        print(String(format: "page turn (120 pages): median %.2f ms, p95 %.2f ms, max %.2f ms", percentile(turns, 0.5),
                     percentile(turns, 0.95), sortedTurns.last ?? 0))
        print(String(format: "  of which (median): page font %.2f ms, layout %.2f ms, drawing %.2f ms",
                     percentile(parts.map(\.font), 0.5), percentile(parts.map(\.layout), 0.5), percentile(parts.map(\.draw), 0.5)))
        print(String(format: "  the same page drawn again: median %.2f ms", percentile(redraws, 0.5)))
        let memory = memory()
        print(String(format: "memory: footprint %.0f MB (Activity Monitor), resident %.0f MB", memory.footprint, memory.resident))
        print("footprint by stage (MB): " + stages.joined(separator: ", "))
        exit(0)
    }
}
#endif

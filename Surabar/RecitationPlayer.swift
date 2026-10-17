import AVFoundation
import Foundation
import MushafRendering
import Observation
import Recitation

/// Plays recitation from original, continuous surah recordings (mp3quran.net), using per-ayah
/// timings to know which ayah is being recited. Consecutive ayahs play straight through, so the
/// reciter's natural endings, breaths, and room sound are kept; playback only jumps for repeats,
/// loops, and new surahs.
@MainActor
@Observable
final class RecitationPlayer {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The step being played or paused.
    private(set) var step: PlaybackStep?
    /// Position within the current ayah, in seconds.
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var reciters: [Reciter]

    /// Called when playback moves to another ayah, so the reader can follow along.
    @ObservationIgnored var onAyahChange: ((AyahKey) -> Void)?

    /// One ayah or basmalah located in a surah recording.
    private struct Segment {
        let step: PlaybackStep
        let rangePass: Int
        let url: URL
        let from: Double
        let to: Double
    }

    private let state: AppState
    private let ayahCounts: [Int]
    private let timings: TimingsStore
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var segment: Segment?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Incremented on every new start, so late results from older requests are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    init(state: AppState, ayahCounts: [Int], reciters: [Reciter], timings: TimingsStore? = nil) {
        self.state = state
        self.ayahCounts = ayahCounts
        self.reciters = reciters
        self.timings = timings ?? TimingsStore(ayahCounts: ayahCounts)
        player.actionAtItemEnd = .pause
        // Relaunch restores the last position, paused. Playback never starts on its own.
        if let ayah = state.lastPlayedAyah, ayahCounts.indices.contains(ayah.surah - 1) {
            step = PlaybackStep(kind: .ayah, ayah: ayah, repetition: 1)
            status = .paused
        }
        observe()
    }

    var reciter: Reciter { reciters.first { $0.id == state.reciterID } ?? reciters[0] }

    var isActive: Bool { status == .playing || status == .loading }

    /// The ayah being recited, or for a basmalah the ayah it introduces.
    var ayah: AyahKey? { step?.ayah }

    // MARK: Controls

    func play(from ayah: AyahKey) {
        start(sequence().start(at: ayah), rangePass: 1)
    }

    /// Resumes a paused ayah, or starts from `ayah` when nothing is paused there.
    func togglePlayPause(startingAt ayah: AyahKey) {
        switch status {
        case .playing, .loading:
            pause()
        case .paused where segment != nil && player.currentItem != nil && step?.ayah == ayah:
            player.playImmediately(atRate: Float(state.speed))
        default:
            play(from: ayah)
        }
    }

    func pause() {
        pendingTask?.cancel()
        player.pause()
        if step != nil { status = .paused }
    }

    /// Moves to the next (+1) or previous (−1) ayah, skipping any remaining repeats.
    func stepAyah(_ direction: Int, from fallback: AyahKey) {
        let current = step?.ayah ?? fallback
        guard let target = direction > 0 ? sequence().ayah(after: current) : sequence().ayah(before: current) else { return }
        let next = PlaybackStep(kind: .ayah, ayah: target, repetition: 1)
        if isActive {
            start(next, rangePass: 1)
        } else {
            stop(at: next)
        }
    }

    /// Seeks within the current ayah.
    func seek(toFraction fraction: Double) {
        guard let segment, segment.to > segment.from else { return }
        let seconds = segment.from + (segment.to - segment.from) * min(max(fraction, 0), 0.99)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seconds - segment.from
    }

    func setSpeed(_ speed: Double) {
        state.speed = speed
        player.defaultRate = Float(speed)
        if player.rate != 0 { player.rate = Float(speed) }
    }

    func setReciter(_ id: Int) {
        guard id != state.reciterID else { return }
        state.reciterID = id
        // Restart the current step in the new voice; a paused position stays paused.
        guard let current = step else { return }
        if isActive { start(current, rangePass: segment?.rangePass ?? 1) } else { stop(at: current) }
    }

    func retry() {
        guard let step else { return }
        start(step, rangePass: segment?.rangePass ?? 1)
    }

    // MARK: Sequencing

    /// Playback currently stops at the end of the surah being played; Phase 6 adds the other boundaries.
    private func sequence(endingWith ayah: AyahKey? = nil) -> PlaybackSequence {
        let end = ayah.map { AyahKey(surah: $0.surah, ayah: ayahCounts[$0.surah - 1]) } ?? AyahKey(surah: 114, ayah: 6)
        return PlaybackSequence(ayahCounts: ayahCounts, boundaryEnd: end)
    }

    private func segment(_ step: PlaybackStep, _ rangePass: Int, _ url: URL, _ span: SurahAudio.Span) -> Segment {
        Segment(step: step, rangePass: rangePass, url: url, from: Double(span.from) / 1000, to: Double(span.to) / 1000)
    }

    /// Locates an ayah step in already-loaded timings, without waiting.
    private func locateCached(_ step: PlaybackStep, rangePass: Int) -> Segment? {
        guard step.kind == .ayah, let audio = timings.cached(reciter: reciter, surah: step.ayah.surah),
              let span = audio.span(of: step.ayah) else { return nil }
        return segment(step, rangePass, audio.audioURL, span)
    }

    /// Locates a step in its recording. The basmalah is the surah file's recorded opening, which then
    /// runs straight into ayah 1; when a file starts directly at ayah 1, it comes from the reciter's
    /// Al-Fatihah, where the basmalah is ayah 1.
    private func resolve(_ step: PlaybackStep, rangePass: Int, reciter: Reciter) async throws -> Segment {
        let audio = try await timings.timings(reciter: reciter, surah: step.ayah.surah)
        if step.kind == .basmalah {
            if let opening = audio.opening { return segment(step, rangePass, audio.audioURL, opening) }
            let fatihah = try await timings.timings(reciter: reciter, surah: 1)
            guard let span = fatihah.span(of: AyahKey(surah: 1, ayah: 1)) else {
                throw RecitationAPI.TimingsError(description: "No basmalah timing")
            }
            return segment(step, rangePass, fatihah.audioURL, span)
        }
        guard let span = audio.span(of: step.ayah) else { throw RecitationAPI.TimingsError(description: "No timing for \(step.ayah)") }
        return segment(step, rangePass, audio.audioURL, span)
    }

    private func start(_ step: PlaybackStep, rangePass: Int) {
        pendingTask?.cancel()
        generation += 1
        let generation = self.generation
        retried = false
        setStep(step)
        status = .loading
        let reciter = self.reciter
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let segment = try await resolve(step, rangePass: rangePass, reciter: reciter)
                guard generation == self.generation else { return }
                play(segment)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                player.pause()
                status = .failed("Couldn't load \(step.ayah). Check your connection")
            }
        }
    }

    /// Plays a located segment: seeks within the loaded recording when it is the same file,
    /// otherwise switches to the queued or a new recording.
    private func play(_ segment: Segment) {
        self.segment = segment
        duration = segment.to - segment.from
        let time = CMTime(seconds: segment.from, preferredTimescale: 1000)
        if currentURL == segment.url {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let items = player.items()
            if items.count > 1, (items[1].asset as? AVURLAsset)?.url == segment.url {
                player.advanceToNextItem()
            } else {
                player.removeAllItems()
                player.insert(AVPlayerItem(url: segment.url), after: nil)
            }
            if segment.from > 0.01 { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        watchEnd(of: segment)
        player.playImmediately(atRate: Float(state.speed))
        prepareFollowing(segment)
    }

    private var currentURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }

    /// Sets a boundary observer at the end of the segment.
    private func watchEnd(of segment: Segment) {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        let end = NSValue(time: CMTime(seconds: segment.to, preferredTimescale: 1000))
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.segmentEnded() }
        }
    }

    /// The current ayah reached its end timestamp, or the recording ended.
    private func segmentEnded() {
        guard let current = segment, isActive else { return }
        guard let next = sequence(endingWith: current.step.ayah).step(after: current.step, rangePass: current.rangePass) else {
            player.pause()
            status = .paused
            return
        }
        // The next ayah follows on in the same recording: keep playing without touching the audio.
        if next.step.repetition == 1, !next.step.pausesBefore,
           let following = locateCached(next.step, rangePass: next.rangePass),
           following.url == current.url, abs(following.from - current.to) < 0.05 {
            segment = following
            setStep(following.step)
            watchEnd(of: following)
            prepareFollowing(following)
            return
        }
        // A repeat, loop, basmalah, or new surah: pause between repeats if configured, then jump.
        let pause = next.step.pausesBefore ? state.repeatPause : 0
        if pause > 0 { player.pause() }
        pendingTask?.cancel()
        generation += 1
        let generation = self.generation
        let reciter = self.reciter
        setStep(next.step)
        pendingTask = Task { [weak self] in
            guard let self else { return }
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
            guard !Task.isCancelled, generation == self.generation else { return }
            guard let segment = try? await resolve(next.step, rangePass: next.rangePass, reciter: reciter) else {
                player.pause()
                status = .failed("Couldn't load \(next.step.ayah). Check your connection")
                return
            }
            guard generation == self.generation else { return }
            play(segment)
        }
    }

    /// Fetches the next step's timings and queues its recording when it is in another file.
    private func prepareFollowing(_ segment: Segment) {
        guard let next = sequence(endingWith: segment.step.ayah).step(after: segment.step, rangePass: segment.rangePass) else { return }
        let reciter = self.reciter
        Task { [weak self] in
            guard let self, let following = try? await resolve(next.step, rangePass: next.rangePass, reciter: reciter) else { return }
            guard self.segment?.step == segment.step, following.url != currentURL else { return }
            let items = player.items()
            if items.count > 1 { player.remove(items[1]) }
            player.insert(AVPlayerItem(url: following.url), after: player.currentItem)
        }
    }

    private func setStep(_ step: PlaybackStep) {
        let changed = self.step?.ayah != step.ayah
        self.step = step
        elapsed = 0
        state.lastPlayedAyah = step.ayah
        if changed { onAyahChange?(step.ayah) }
    }

    /// Shows an ayah as the paused position without loading audio.
    private func stop(at step: PlaybackStep) {
        pendingTask?.cancel()
        generation += 1
        player.pause()
        player.removeAllItems()
        segment = nil
        setStep(step)
        duration = 0
        status = .paused
    }

    // MARK: Observation

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                // A recording can end a moment before the last ayah's timestamp.
                if let self, item === self.player.currentItem { self.segmentEnded() }
            }
        })
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let control = player.timeControlStatus
            let failed = player.currentItem?.status == .failed
            Task { @MainActor in self?.timeControlChanged(control, itemFailed: failed) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func timeControlChanged(_ control: AVPlayer.TimeControlStatus, itemFailed: Bool) {
        if itemFailed { return itemFailedToLoad() }
        if case .failed = status { return }
        switch control {
        case .playing: status = .playing
        case .waitingToPlayAtSpecifiedRate: status = .loading
        case .paused: if status == .playing { status = .paused }
        @unknown default: break
        }
    }

    private func tick(_ time: CMTime) {
        guard let segment else { return }
        duration = segment.to - segment.from
        elapsed = min(max(time.seconds - segment.from, 0), duration)
        if player.currentItem?.status == .failed { itemFailedToLoad() }
    }

    /// Retry the recording once, then pause on the ayah and offer Retry.
    private func itemFailedToLoad() {
        guard let segment else { return }
        if !retried {
            retried = true
            player.removeAllItems()
            play(segment)
            return
        }
        player.pause()
        status = .failed("Couldn't load \(segment.step.ayah). Check your connection")
    }

    #if DEBUG
    /// For the debug playback probe only.
    var debugQueuePlayer: AVQueuePlayer { player }
    #endif
}

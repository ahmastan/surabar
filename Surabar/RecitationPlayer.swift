import AVFoundation
import Foundation
import MushafRendering
import Network
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

    /// The fraction of the current ayah played, as last measured (once a second, and at every change).
    /// The progress line animates on from there by itself while playing.
    var progressFraction: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
    private(set) var reciters: [Reciter]

    /// Called when playback moves to another ayah, so the reader can follow along.
    @ObservationIgnored var onAyahChange: ((AyahKey) -> Void)?
    /// Called when the user starts or moves playback, before the ayah changes, so the reader follows it again.
    @ObservationIgnored var onUserAction: (() -> Void)?
    /// The ayahs that start on the page where an ayah starts, in the current layout.
    @ObservationIgnored var pageRange: ((AyahKey) -> ClosedRange<AyahKey>?)?
    /// Whether the reader is showing the Manzil, so playing starts the Manzil and the Loop sets how often
    /// it repeats; set by the app.
    @ObservationIgnored var readsManzil: () -> Bool = { false }
    /// Called when Play Manzil has recited the whole Manzil (all its repeats).
    @ObservationIgnored var onManzilFinished: (() -> Void)?
    /// Called after the position jumps within an ayah, so Now Playing shows it.
    @ObservationIgnored var onSeek: (() -> Void)?
    /// The last ayah of the page or juz an ayah is in, for "Stop playback at".
    @ObservationIgnored var unitEnd: ((AyahKey, PlaybackStop) -> AyahKey?)?

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
    private let audio: AudioCache
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var online = true
    @ObservationIgnored private var segment: Segment?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Incremented on every new start, so late results from older requests are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    /// The surah or page the Loop repeats, fixed where playback starts or the loop is turned on,
    /// so the loop stays on it even when an ayah crosses a page.
    @ObservationIgnored private var loopRange: ClosedRange<AyahKey>?

    init(state: AppState, ayahCounts: [Int], reciters: [Reciter], timings: TimingsStore, audio: AudioCache) {
        self.state = state
        self.ayahCounts = ayahCounts
        self.reciters = reciters
        self.timings = timings
        self.audio = audio
        player.actionAtItemEnd = .pause
        player.volume = Float(state.volume)
        // Relaunch restores the last position, paused. Playback never starts on its own.
        if let ayah = state.lastPlayedAyah, ayahCounts.indices.contains(ayah.surah - 1) {
            step = PlaybackStep(kind: .ayah, ayah: ayah, repetition: 1)
            status = .paused
        }
        observe()
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.online = online }
        }
        network.start(queue: .main)
    }

    var reciter: Reciter { reciters.first { $0.id == state.reciterID } ?? reciters[0] }

    var isActive: Bool { status == .playing || status == .loading }

    /// The ayah being recited, or for a basmalah the ayah it introduces.
    var ayah: AyahKey? { step?.ayah }

    // MARK: Controls

    /// Plays from an ayah of the mushaf. Playing outside the Manzil ends the Manzil mode, whose playlist
    /// would otherwise send playback back to its first passage after this ayah.
    func play(from ayah: AyahKey) {
        if state.loopMode == .manzil { state.loopMode = .off }
        begin(at: ayah)
    }

    private func begin(at ayah: AyahKey) {
        onUserAction?()
        anchorLoop(at: ayah)
        start(sequence(at: ayah).start(at: ayah), rangePass: firstPass(at: ayah))
    }

    /// The reader left the Manzil: unless the Manzil is still playing, the Loop and transport return to
    /// the mushaf.
    func leftManzil() {
        if state.loopMode == .manzil && !isActive { state.loopMode = .off }
    }

    /// Resumes a paused ayah, or starts from `ayah` when nothing is paused there.
    func togglePlayPause(startingAt ayah: AyahKey) {
        switch status {
        case .playing, .loading:
            pause()
        case .paused where segment != nil && player.currentItem != nil && step?.ayah == ayah:
            onUserAction?()
            player.playImmediately(atRate: Float(state.speed))
        default:
            if readsManzil() { playManzil(from: ayah) } else { play(from: ayah) }
        }
    }

    /// The Manzil is playing or being read: the transport and the Loop work on the Manzil.
    var inManzil: Bool { state.loopMode == .manzil || readsManzil() }

    func pause() {
        pendingTask?.cancel()
        player.pause()
        if step != nil { status = .paused }
    }

    /// Moves to the next (+1) or previous (−1) ayah, skipping any remaining repeats.
    func stepAyah(_ direction: Int, from fallback: AyahKey) {
        let current = step?.ayah ?? fallback
        // In the Manzil, previous and next move through its ayahs, across passages.
        if inManzil {
            guard let target = Manzil.ayah(direction, from: current) else { return }
            return move(to: PlaybackStep(kind: .ayah, ayah: target, repetition: 1))
        }
        let sequence = sequence(at: current)
        guard let target = direction > 0 ? sequence.ayah(after: current) : sequence.ayah(before: current) else { return }
        move(to: PlaybackStep(kind: .ayah, ayah: target, repetition: 1))
    }

    /// Moves to an ayah chosen by the skip buttons: it plays from there (with the basmalah at a
    /// surah's start) when playing, otherwise it becomes the paused position.
    func skip(to ayah: AyahKey) {
        move(to: isActive ? sequence(at: ayah).start(at: ayah) : PlaybackStep(kind: .ayah, ayah: ayah, repetition: 1))
    }

    private func move(to step: PlaybackStep) {
        onUserAction?()
        anchorLoop(at: step.ayah)
        if isActive { start(step, rangePass: firstPass(at: step.ayah)) } else { stop(at: step) }
    }

    /// Off → repeat ayah → repeat surah or page → off. In the Manzil: once → 3× → 7× → until stopped.
    func cycleLoop() {
        if inManzil {
            let counts = AppState.manzilRepeatCounts
            state.manzilRepeats = counts[((counts.firstIndex(of: state.manzilRepeats) ?? 0) + 1) % counts.count]
            return
        }
        setLoop(state.loopMode.next)
    }

    /// Recites the Manzil from its first passage (or from `ayah`, when it is in the Manzil).
    func playManzil(from ayah: AyahKey? = nil) {
        state.loopMode = .manzil
        loopRange = nil
        begin(at: ayah.flatMap { Manzil.passage(containing: $0) != nil ? $0 : nil } ?? Manzil.passages[0].lowerBound)
    }

    /// Repeats the ayahs from one to another (in either order), starting at the first.
    func loop(_ range: ClosedRange<AyahKey>) {
        state.loopRange = range
        state.loopMode = .range
        loopRange = nil
        play(from: range.lowerBound)
    }

    func setLoop(_ mode: LoopMode) {
        guard mode != .range || state.loopRange != nil, mode != .manzil else { return }
        state.loopMode = mode
        loopRange = nil
        guard let ayah = step?.ayah else { return }
        anchorLoop(at: ayah)
        if let segment {
            self.segment = Segment(step: segment.step, rangePass: firstPass(at: ayah), url: segment.url, from: segment.from, to: segment.to)
        }
    }

    /// Repeating a surah or page counts full passes: a pass started part-way through is pass 0.
    private func firstPass(at ayah: AyahKey) -> Int {
        let range = state.loopMode == .range ? state.loopRange : state.loopMode == .unit ? loopRange : nil
        guard let range, ayah != range.lowerBound else { return 1 }
        return 0
    }

    /// Fixes the surah or page to repeat when the loop repeats one and `ayah` is outside it.
    private func anchorLoop(at ayah: AyahKey) {
        guard state.loopMode == .unit else { loopRange = nil; return }
        if let loopRange, loopRange.contains(ayah) { return }
        loopRange = unitRange(of: ayah)
    }

    private func unitRange(of ayah: AyahKey) -> ClosedRange<AyahKey>? {
        switch state.skipUnit {
        case .surah: AyahKey(surah: ayah.surah, ayah: 1) ... AyahKey(surah: ayah.surah, ayah: ayahCounts[ayah.surah - 1])
        case .page: pageRange?(ayah)
        }
    }

    /// Seeks within the current ayah.
    func seek(toFraction fraction: Double) {
        guard let segment, segment.to > segment.from else { return }
        let seconds = segment.from + (segment.to - segment.from) * min(max(fraction, 0), 0.99)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seconds - segment.from
        onSeek?()
    }

    func setSpeed(_ speed: Double) {
        state.speed = speed
        player.defaultRate = Float(speed)
        if player.rate != 0 { player.rate = Float(speed) }
    }

    func setVolume(_ volume: Double) {
        state.volume = min(max(volume, 0), 1)
        player.volume = Float(state.volume)
    }

    func setReciter(_ id: Int) {
        guard id != state.reciterID else { return }
        state.reciterID = id
        // Restart the current step in the new voice; a paused position stays paused.
        guard let current = step else { return }
        if isActive { start(current, rangePass: segment?.rangePass ?? firstPass(at: current.ayah)) } else { stop(at: current) }
    }

    func retry() {
        guard let step else { return }
        start(step, rangePass: segment?.rangePass ?? 1)
    }

    // MARK: Sequencing

    /// The playback order around `ayah` with the current Loop settings. Without a loop, playback stops
    /// at the end of the page, surah, juz, or Quran the ayah is in (Settings › Player).
    func sequence(at ayah: AyahKey) -> PlaybackSequence {
        let surahEnd = AyahKey(surah: ayah.surah, ayah: ayahCounts[ayah.surah - 1])
        let end: AyahKey = switch state.playbackStop {
        case .surah: surahEnd
        case .quran: AyahKey(surah: ayahCounts.count, ayah: ayahCounts[ayahCounts.count - 1])
        case .page, .juz: unitEnd?(ayah, state.playbackStop) ?? surahEnd
        }
        var sequence = PlaybackSequence(ayahCounts: ayahCounts, boundaryEnd: end)
        let count: RepeatCount = state.repeatCount == 0 ? .forever : .times(state.repeatCount)
        switch state.loopMode {
        case .off:
            break
        case .ayah:
            sequence.ayahRepeats = count
        case .unit:
            sequence.range = loopRange ?? unitRange(of: ayah)
            sequence.rangeRepeats = count
        case .range:
            sequence.range = state.loopRange
            sequence.rangeRepeats = count
        case .manzil:
            sequence.playlist = Manzil.passages
            sequence.rangeRepeats = state.manzilRepeats == 0 ? .forever : .times(state.manzilRepeats)
        }
        return sequence
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
                status = .failed(failureMessage(step.ayah))
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
            if items.count > 1, (items[1].asset as? AVURLAsset).map({ AudioCache.remoteURL(for: $0.url) }) == segment.url {
                player.advanceToNextItem()
            } else {
                player.removeAllItems()
                player.insert(item(segment.url), after: nil)
            }
            if segment.from > 0.01 { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        watchEnd(of: segment)
        player.playImmediately(atRate: Float(state.speed))
        prepareFollowing(segment)
    }

    /// The remote URL of the recording being played (items load through the audio cache's scheme).
    private var currentURL: URL? { (player.currentItem?.asset as? AVURLAsset).map { AudioCache.remoteURL(for: $0.url) } }

    private func item(_ url: URL) -> AVPlayerItem {
        AVPlayerItem(asset: audio.asset(for: url))
    }

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
        guard let next = sequence(at: current.step.ayah).step(after: current.step, rangePass: current.rangePass) else {
            player.pause()
            status = .paused
            if state.loopMode == .manzil {
                state.loopMode = .off
                onManzilFinished?()
            }
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
                status = .failed(failureMessage(next.step.ayah))
                return
            }
            guard generation == self.generation else { return }
            play(segment)
        }
    }

    /// Fetches the next step's timings and queues its recording when it is in another file.
    private func prepareFollowing(_ segment: Segment) {
        guard let next = sequence(at: segment.step.ayah).step(after: segment.step, rangePass: segment.rangePass) else { return }
        let reciter = self.reciter
        Task { [weak self] in
            guard let self, let following = try? await resolve(next.step, rangePass: next.rangePass, reciter: reciter) else { return }
            guard self.segment?.step == segment.step, following.url != currentURL else { return }
            let items = player.items()
            if items.count > 1 { player.remove(items[1]) }
            player.insert(item(following.url), after: player.currentItem)
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
        // Once a second: the position for the audio cache and accessibility. Ayah ends use boundary
        // observers, and the progress line animates by itself, so nothing needs a faster tick.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: .main) { [weak self] time in
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
        // Observers are told of every assignment, so only assign changes.
        let length = segment.to - segment.from
        if duration != length { duration = length }
        let position = min(max(time.seconds - segment.from, 0), length)
        if abs(position - elapsed) > 0.01 { elapsed = position }
        // The cache fetches a few minutes past this point.
        if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0, let url = currentURL {
            audio.setPlayhead(time.seconds / total, of: url)
        }
        if player.currentItem?.status == .failed { itemFailedToLoad() }
    }

    /// Offline, audio that was never saved cannot play; otherwise the connection or the server failed.
    private func failureMessage(_ ayah: AyahKey) -> String {
        online ? "Couldn't load \(ayah). Check your connection" : "\(ayah) isn't downloaded. You're offline"
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
        status = .failed(failureMessage(segment.step.ayah))
    }

    #if DEBUG
    /// For the debug playback probe only.
    var debugQueuePlayer: AVQueuePlayer { player }
    #endif
}

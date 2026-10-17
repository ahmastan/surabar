import Foundation
import Observation
import Recitation

/// Downloads for offline listening, per reciter: surahs and juz, with their progress and storage.
/// Mirrors the audio cache's state for the interface.
@MainActor
@Observable
final class DownloadCenter {
    enum Status: Equatable {
        case none
        /// Partly stored while playing (fraction stored).
        case partial(Double)
        case downloading(Double)
        case downloaded
    }

    private(set) var files: [String: CachedAudioState] = [:]
    private(set) var downloading: [String: Double] = [:]
    /// Surahs whose download is preparing (fetching timings) before the audio starts.
    private(set) var preparing: Set<String> = []

    private let audio: AudioCache
    private let timings: TimingsStore
    private let state: AppState

    init(audio: AudioCache, timings: TimingsStore, state: AppState) {
        self.audio = audio
        self.timings = timings
        self.state = state
        audio.setBudget(state.cacheBudget)
        audio.observe { [weak self] summary in
            Task { @MainActor in
                self?.files = summary.files
                self?.downloading = summary.downloading
            }
        }
    }

    // MARK: Status

    func key(surah: Int, reciter: Reciter) -> String {
        AudioCache.key(for: reciter.audioURL(surah: surah))
    }

    func status(surah: Int, reciter: Reciter) -> Status {
        let key = key(surah: surah, reciter: reciter)
        if let progress = downloading[key] { return .downloading(progress) }
        if preparing.contains(key) { return .downloading(0) }
        guard let file = files[key] else { return .none }
        if file.pinned && file.isComplete { return .downloaded }
        return file.chunks.isEmpty ? .none : .partial(file.fractionStored)
    }

    /// A group (a juz) is downloaded when all its surahs are; its progress averages theirs.
    func status(surahs: [Int], reciter: Reciter) -> Status {
        var progress = 0.0
        var active = false
        for surah in surahs {
            switch status(surah: surah, reciter: reciter) {
            case .downloaded: progress += 1
            case .downloading(let fraction): progress += fraction; active = true
            case .none, .partial: break
            }
        }
        if progress == Double(surahs.count) { return .downloaded }
        return active ? .downloading(progress / Double(surahs.count)) : .none
    }

    /// Bytes kept as downloads, and bytes saved while playing.
    var downloadedBytes: Int { files.values.filter(\.pinned).reduce(0) { $0 + $1.storedBytes } }
    var cachedBytes: Int { files.values.filter { !$0.pinned }.reduce(0) { $0 + $1.storedBytes } }

    /// Downloaded surahs of a reciter.
    func downloadedSurahs(reciter: Reciter) -> [Int] {
        (1 ... 114).filter { status(surah: $0, reciter: reciter) == .downloaded }
    }

    // MARK: Actions

    /// Downloads surahs with their timings. When a reciter's recordings start straight at ayah 1, the
    /// basmalah comes from their Al-Fatihah, so that is downloaded too.
    func download(surahs: [Int], reciter: Reciter) {
        for surah in surahs {
            let key = key(surah: surah, reciter: reciter)
            guard status(surah: surah, reciter: reciter) != .downloaded, downloading[key] == nil, !preparing.contains(key) else { continue }
            preparing.insert(key)
            Task {
                defer { preparing.remove(key) }
                guard let audio = try? await timings.timings(reciter: reciter, surah: surah) else { return }
                if audio.opening == nil, surah != 1, surah != 9, (try? await timings.timings(reciter: reciter, surah: 1)) != nil,
                   status(surah: 1, reciter: reciter) != .downloaded {
                    self.audio.download(reciter.audioURL(surah: 1))
                }
                self.audio.download(reciter.audioURL(surah: surah))
                downloading[key] = downloading[key] ?? 0
            }
        }
    }

    func cancel(surahs: [Int], reciter: Reciter) {
        for surah in surahs {
            preparing.remove(key(surah: surah, reciter: reciter))
            audio.cancelDownload(reciter.audioURL(surah: surah))
        }
    }

    func delete(surahs: [Int], reciter: Reciter) {
        for surah in surahs { audio.delete(reciter.audioURL(surah: surah)) }
    }

    func clearCache() {
        audio.clearCache()
    }

    func setBudget(_ bytes: Int) {
        state.cacheBudget = bytes
        audio.setBudget(bytes)
    }
}

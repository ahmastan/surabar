import Foundation
import Recitation

/// Reciters with continuous recordings and ayah timings, checked when the bundled list was made:
/// Hafs readings whose surah files are constant-bitrate (so seeking is exact) with complete timings.
enum ReciterCatalogLoader {
    static func bundled(from bundle: Bundle = .main) -> [Reciter] {
        let fallback = [Reciter(id: Reciter.defaultID, name: "Mishary Rashid Alafasy", style: nil,
                                server: URL(string: "https://cdn.mp3quran.net/audio/mishary-alafasy/r1/")!)]
        guard let url = bundle.url(forResource: "reciters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let reciters = try? JSONDecoder().decode([Reciter].self, from: data), !reciters.isEmpty else { return fallback }
        return reciters
    }
}

/// Ayah timings per reciter and surah, fetched once and kept on disk (a few kilobytes each).
@MainActor
final class TimingsStore {
    private let ayahCounts: [Int]
    private let session: URLSession
    private var memory: [String: SurahAudio] = [:]
    private var inFlight: [String: Task<SurahAudio, Error>] = [:]

    init(ayahCounts: [Int], session: URLSession = .shared) {
        self.ayahCounts = ayahCounts
        self.session = session
    }

    /// Timings already in memory or on disk, without a network request.
    func cached(reciter: Reciter, surah: Int) -> SurahAudio? {
        let key = "\(reciter.id)/\(surah)"
        if let audio = memory[key] { return audio }
        guard let data = try? Data(contentsOf: fileURL(key)), let audio = try? JSONDecoder().decode(SurahAudio.self, from: data) else {
            return nil
        }
        memory[key] = audio
        return audio
    }

    func timings(reciter: Reciter, surah: Int) async throws -> SurahAudio {
        if let audio = cached(reciter: reciter, surah: surah) { return audio }
        let key = "\(reciter.id)/\(surah)"
        if let task = inFlight[key] { return try await task.value }
        let session = self.session, count = ayahCounts[surah - 1], url = fileURL(key)
        let task = Task<SurahAudio, Error> {
            let (data, response) = try await session.data(from: RecitationAPI.timingsURL(reciter: reciter.id, surah: surah))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw RecitationAPI.TimingsError(description: "The recitation service is unavailable")
            }
            let audio = try RecitationAPI.decodeTimings(data, ayahCount: count, surah: surah, audioURL: reciter.audioURL(surah: surah))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(audio).write(to: url, options: .atomic)
            return audio
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let audio = try await task.value
        memory[key] = audio
        return audio
    }

    private func fileURL(_ key: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Surabar/Timings/mp3quran/\(key).json")
    }
}

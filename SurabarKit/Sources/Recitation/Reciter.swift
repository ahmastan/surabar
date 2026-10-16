import Foundation
import MushafRendering

/// A reciter with original, continuous surah recordings and per-ayah timings, as published by
/// mp3quran.net. These are studio albums, not per-ayah clips joined together, so the reciter's
/// endings, breaths, and room sound carry through from one ayah to the next.
public struct Reciter: Codable, Hashable, Sendable, Identifiable {
    /// The mp3quran.net ayah-timing reading ID ("read").
    public let id: Int
    public let name: String
    /// "Mujawwad", or nil for murattal.
    public let style: String?
    /// The folder holding 001.mp3 … 114.mp3.
    public let server: URL

    public init(id: Int, name: String, style: String?, server: URL) {
        self.id = id
        self.name = name
        self.style = style
        self.server = server
    }

    public var displayName: String { style.map { "\(name) (\($0))" } ?? name }

    public func audioURL(surah: Int) -> URL {
        server.appending(path: String(format: "%03d.mp3", surah))
    }

    public static let defaultID = 123
}

/// Where each ayah sits in a surah's recording, in milliseconds.
public struct SurahAudio: Codable, Hashable, Sendable {
    public struct Span: Codable, Hashable, Sendable {
        public let from: Int
        public let to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public let audioURL: URL
    public let spans: [String: Span]
    /// The recorded opening before ayah 1 (the basmalah, sometimes with the isti'adhah), when present.
    public let opening: Span?

    public init(audioURL: URL, spans: [String: Span], opening: Span?) {
        self.audioURL = audioURL
        self.spans = spans
        self.opening = opening
    }

    public func span(of ayah: AyahKey) -> Span? { spans[ayah.description] }
}

/// The mp3quran.net API v3 endpoint used for recitation timings.
public enum RecitationAPI {
    public static func timingsURL(reciter: Int, surah: Int) -> URL {
        URL(string: "https://mp3quran.net/api/v3/ayat_timing?surah=\(surah)&read=\(reciter)")!
    }

    /// An opening shorter than this is lead-in silence, not a recorded basmalah.
    public static let minimumOpening = 1500

    public struct TimingsError: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    struct Entry: Decodable {
        let ayah: Int
        let start_time: Int
        let end_time: Int
    }

    /// Decodes a surah's timings, requiring a span for every ayah. Entry 0, when present, is the opening.
    public static func decodeTimings(_ data: Data, ayahCount: Int, surah: Int, audioURL: URL) throws -> SurahAudio {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var spans: [String: SurahAudio.Span] = [:]
        for entry in entries where entry.ayah >= 1 && entry.end_time > entry.start_time {
            spans["\(surah):\(entry.ayah)"] = SurahAudio.Span(from: entry.start_time, to: entry.end_time)
        }
        let missing = (1 ... ayahCount).filter { spans["\(surah):\($0)"] == nil }
        guard missing.isEmpty else {
            throw TimingsError(description: "Surah \(surah) timings lack ayah \(missing[0])")
        }
        let first = spans["\(surah):1"]!.from
        let opening = first >= minimumOpening ? SurahAudio.Span(from: 0, to: first) : nil
        return SurahAudio(audioURL: audioURL, spans: spans, opening: opening)
    }
}

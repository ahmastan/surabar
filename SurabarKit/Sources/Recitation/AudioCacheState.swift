import Foundation

/// What is stored of one surah recording: the file is kept in fixed-size chunks, fetched as they are
/// played or downloaded, so a recording heard once plays offline afterwards without being fetched twice.
public struct CachedAudioState: Codable, Equatable, Sendable {
    /// 512 KB, about 33 seconds at 128 kbps.
    public static let chunkSize = 512 * 1024

    /// The recording's size in bytes.
    public var length: Int
    /// The server's version of the file; a different one means the stored chunks are stale.
    public var etag: String?
    public var chunks = IndexSet()
    /// Downloaded on request: kept until deleted, never evicted.
    public var pinned = false
    public var lastUsed: Date

    public init(length: Int, etag: String?, lastUsed: Date = Date()) {
        self.length = length
        self.etag = etag
        self.lastUsed = lastUsed
    }

    public var chunkCount: Int { (length + Self.chunkSize - 1) / Self.chunkSize }

    public var isComplete: Bool { chunkCount > 0 && chunks.count == chunkCount }

    /// The bytes of a chunk; the last one is usually shorter.
    public func byteRange(ofChunk index: Int) -> Range<Int> {
        index * Self.chunkSize ..< min((index + 1) * Self.chunkSize, length)
    }

    public static func chunk(containing offset: Int) -> Int { offset / chunkSize }

    /// Bytes stored on disk.
    public var storedBytes: Int {
        chunks.reduce(0) { $0 + byteRange(ofChunk: $1).count }
    }

    public var fractionStored: Double { length > 0 ? Double(storedBytes) / Double(length) : 0 }

    /// The missing chunks in `range`, as runs of at most `maxRun` consecutive chunks, in order.
    public func missingRuns(in range: Range<Int>, maxRun: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in range.clamped(to: 0 ..< chunkCount) {
            if chunks.contains(index) {
                if let begin = start { runs.append(begin ..< index); start = nil }
            } else if let begin = start, index - begin == maxRun {
                runs.append(begin ..< index)
                start = index
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { runs.append(begin ..< min(range.upperBound, chunkCount)) }
        return runs
    }
}

/// An HTTP Content-Range header value such as "bytes 0-524287/112345678".
public struct ContentRange: Equatable, Sendable {
    public let first: Int
    public let last: Int
    public let total: Int

    public init?(_ header: String) {
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/")
        let bounds = rangeAndTotal.first?.split(separator: "-") ?? []
        guard rangeAndTotal.count == 2, bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
              let total = Int(rangeAndTotal[1]), first <= last, last < total else { return nil }
        self.first = first
        self.last = last
        self.total = total
    }
}

public enum AudioCachePolicy {
    /// The default space for recordings saved while playing (downloads are counted separately).
    public static let defaultBudget = 1_000_000_000

    /// Which saved recordings to remove, least recently used first, so the rest fit the budget.
    /// Downloads (pinned) and recordings in use are never removed.
    public static func evictions(_ files: [String: CachedAudioState], budget: Int, inUse: Set<String>) -> [String] {
        let evictable = files.filter { !$0.value.pinned }
        var total = evictable.values.reduce(0) { $0 + $1.storedBytes }
        var removed: [String] = []
        for (key, state) in evictable.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > budget {
            guard !inUse.contains(key) else { continue }
            total -= state.storedBytes
            removed.append(key)
        }
        return removed
    }
}

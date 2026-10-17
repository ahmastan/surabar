import Foundation
import Recitation
import Testing
@testable import Surabar

/// A recording server stub: deterministic bytes, byte ranges, an ETag, and If-Range.
private final class RecordingServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var etag = "\"v1\""
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var bytesServed = 0
    static let lock = NSLock()

    static func reset(length: Int, etag: String = "\"v1\"", seed: UInt8 = 1) {
        lock.withLock {
            body = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
            Self.etag = etag
            requests = 0
            bytesServed = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, etag) = Self.lock.withLock { (Self.body, Self.etag) }
        var status = 200
        var headers = ["ETag": etag, "Content-Type": "audio/mpeg"]
        var slice = body
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        if let range = request.value(forHTTPHeaderField: "Range"), ifRange == nil || ifRange == etag,
           range.hasPrefix("bytes="), case let bounds = range.dropFirst(6).split(separator: "-"), bounds.count == 2,
           let first = Int(bounds[0]), let last = Int(bounds[1]) {
            let end = min(last, body.count - 1)
            slice = body.subdata(in: first ..< end + 1)
            status = 206
            headers["Content-Range"] = "bytes \(first)-\(end)/\(body.count)"
        }
        headers["Content-Length"] = "\(slice.count)"
        Self.lock.withLock {
            Self.requests += 1
            Self.bytesServed += slice.count
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The latest summary reported by a cache.
private final class SummaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AudioCache.Summary?

    func set(_ summary: AudioCache.Summary) { lock.withLock { value = summary } }
    func get() -> AudioCache.Summary? { lock.withLock { value } }
}

@Suite(.serialized)
struct AudioCacheTests {
    private let url = URL(string: "https://cdn.example.invalid/audio/reciter/r1/002.mp3")!
    private let key = "reciter/r1/002"

    private func makeCache(root: URL) -> (AudioCache, SummaryBox) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingServer.self]
        let cache = AudioCache(root: root, configuration: configuration)
        let box = SummaryBox()
        cache.observe { box.set($0) }
        return (cache, box)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("surabar-audio-\(UUID().uuidString)")
    }

    /// Waits up to five seconds for the cache to report a state.
    private func wait(_ box: SummaryBox, until condition: (AudioCache.Summary) -> Bool) async -> AudioCache.Summary? {
        for _ in 0 ..< 250 {
            if let summary = box.get(), condition(summary) { return summary }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return box.get()
    }

    @Test func keysFollowTheServerPath() {
        #expect(AudioCache.key(for: url) == key)
        let asset = AudioCache(root: temporaryRoot()).asset(for: url)
        #expect(asset.url.scheme == AudioCache.scheme)
        #expect(AudioCache.remoteURL(for: asset.url) == url)
    }

    @Test func downloadsAWholeRecordingOnceAndKeepsIt() async throws {
        let length = CachedAudioState.chunkSize * 3 + 1234
        RecordingServer.reset(length: length)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (cache, box) = makeCache(root: root)
        cache.download(url)
        let summary = await wait(box) { $0.files[key]?.isComplete == true && $0.downloading.isEmpty }
        let state = try #require(summary?.files[key])
        #expect(state.pinned && state.isComplete && state.length == length)
        #expect(try Data(contentsOf: root.appending(path: key + ".mp3")) == RecordingServer.body)
        #expect(RecordingServer.bytesServed == length, "every byte fetched once")

        // A new cache over the same folder finds it; downloading again fetches nothing.
        let (again, box2) = makeCache(root: root)
        let requests = RecordingServer.requests
        again.download(url)
        let reloaded = await wait(box2) { $0.files[key]?.isComplete == true && $0.downloading.isEmpty }
        #expect(reloaded?.files[key]?.pinned == true)
        #expect(RecordingServer.requests == requests)
    }

    @Test func aChangedFileOnTheServerIsFetchedAfresh() async throws {
        let length = CachedAudioState.chunkSize * 2 + 10
        RecordingServer.reset(length: length, etag: "\"old\"", seed: 1)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A partly stored older version of the recording.
        var stale = CachedAudioState(length: length, etag: "\"old\"")
        stale.chunks.insert(0)
        try FileManager.default.createDirectory(at: root.appending(path: "reciter/r1"), withIntermediateDirectories: true)
        try RecordingServer.body.write(to: root.appending(path: key + ".mp3"))
        try JSONEncoder().encode(stale).write(to: root.appending(path: key + ".json"))

        RecordingServer.reset(length: length, etag: "\"new\"", seed: 7)
        let (cache, box) = makeCache(root: root)
        cache.download(url)
        let summary = await wait(box) { $0.files[key]?.isComplete == true && $0.downloading.isEmpty }
        #expect(summary?.files[key]?.etag == "\"new\"")
        #expect(try Data(contentsOf: root.appending(path: key + ".mp3")) == RecordingServer.body, "no stale bytes remain")
    }

    @Test func deletingRemovesTheRecording() async throws {
        RecordingServer.reset(length: 5000)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (cache, box) = makeCache(root: root)
        cache.download(url)
        _ = await wait(box) { $0.files[key]?.isComplete == true && $0.downloading.isEmpty }
        cache.delete(url)
        let summary = await wait(box) { $0.files[key] == nil }
        #expect(summary?.files[key] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: key + ".mp3").path))
    }

    @Test func clearingTheCacheKeepsDownloads() async throws {
        RecordingServer.reset(length: 5000)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // An unpinned recording saved while playing, beside a download.
        var played = CachedAudioState(length: 5000, etag: "\"v1\"")
        played.chunks.insert(0)
        try FileManager.default.createDirectory(at: root.appending(path: "reciter/r1"), withIntermediateDirectories: true)
        try RecordingServer.body.write(to: root.appending(path: "reciter/r1/001.mp3"))
        try JSONEncoder().encode(played).write(to: root.appending(path: "reciter/r1/001.json"))
        let (cache, box) = makeCache(root: root)
        cache.download(url)
        _ = await wait(box) { $0.files[key]?.isComplete == true && $0.downloading.isEmpty && $0.files["reciter/r1/001"] != nil }
        cache.clearCache()
        let summary = await wait(box) { $0.files["reciter/r1/001"] == nil }
        #expect(summary?.files["reciter/r1/001"] == nil)
        #expect(summary?.files[key]?.pinned == true)
    }
}

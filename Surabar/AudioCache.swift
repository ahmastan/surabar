import AVFoundation
import Foundation
import Recitation
import UniformTypeIdentifiers

/// Surah recordings saved as they play. The player reads every recording through this cache (a custom
/// URL scheme and an AVFoundation resource loader), which serves stored chunks from disk and fetches
/// missing ones with HTTP range requests, writing them to disk as they arrive. Each byte is fetched
/// once: a recording heard before plays offline. Open-ended reads fetch at most `readAhead` past the
/// playhead, so listening to one ayah of a long surah does not download all of it. Downloads (pinned)
/// fetch whole files and are never evicted; other recordings are evicted, least recently used first,
/// beyond the budget.
///
/// All state is confined to `queue`; AVFoundation and URLSession call back on it.
final class AudioCache: NSObject, @unchecked Sendable {
    static let scheme = "surabar-audio"
    /// About four minutes at 128 kbps.
    static let readAhead = 4 * 1024 * 1024
    /// The most chunks fetched by one request (8 MB).
    static let maxRun = 16

    struct Summary: Sendable {
        var files: [String: CachedAudioState]
        /// Progress of downloads in progress, by key.
        var downloading: [String: Double]
    }

    let queue = DispatchQueue(label: "io.github.ahmastan.surabar.audio-cache")
    private let root: URL
    private var session: URLSession!
    private var files: [String: CachedAudioState] = [:]
    private var handles: [String: FileHandle] = [:]
    private var fetches: [Int: Fetch] = [:]
    /// Chunks being fetched, and who waits for each.
    private var waiters: [String: [Int: [(Error?) -> Void]]] = [:]
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var playheads: [String: Int] = [:]
    private var downloads: [String: Download] = [:]
    private var notifyScheduled = false
    private var budget = AudioCachePolicy.defaultBudget
    private var onChange: (@Sendable (Summary) -> Void)?

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Surabar/Audio"), configuration: URLSessionConfiguration = .default) {
        self.root = root
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        queue.async { self.loadIndex() }
    }

    /// Reports stored recordings and download progress, on the main queue, whenever they change.
    func observe(_ handler: @escaping @Sendable (Summary) -> Void) {
        queue.async {
            self.onChange = handler
            self.scheduleNotify()
        }
    }

    func setBudget(_ bytes: Int) {
        queue.async {
            self.budget = bytes
            self.evict()
        }
    }

    // MARK: Keys and URLs

    /// A recording's identity: its path on the audio server without the extension, e.g. "mishary-alafasy/r1/002".
    static func key(for url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/audio/") { path.removeFirst("/audio/".count) }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".mp3") { path.removeLast(4) }
        return path
    }

    /// The asset the player plays: the remote URL with the cache's scheme, loaded through this cache.
    func asset(for url: URL) -> AVURLAsset {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// The remote URL behind a player asset's URL.
    static func remoteURL(for url: URL) -> URL {
        guard url.scheme == scheme, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// Where the player is in a recording (0–1), which bounds how far ahead it is fetched.
    func setPlayhead(_ fraction: Double, of url: URL) {
        let key = Self.key(for: url)
        queue.async {
            guard let length = self.files[key]?.length else { return }
            let offset = Int(Double(length) * min(max(fraction, 0), 1))
            guard offset != self.playheads[key] else { return }
            self.playheads = [key: offset]
            // Reads waiting for the playhead to move on can continue.
            for job in self.jobs.values where job.key == key && job.parked {
                job.parked = false
                self.process(job)
            }
        }
    }

    // MARK: Downloads

    /// Downloads a whole recording and keeps it until deleted.
    func download(_ url: URL) {
        let key = Self.key(for: url)
        queue.async {
            guard self.downloads[key] == nil else { return }
            self.downloads[key] = Download(url: url)
            self.files[key]?.pinned = true
            self.continueDownload(key)
        }
    }

    /// Stops a download; what was fetched stays as ordinary cache.
    func cancelDownload(_ url: URL) {
        let key = Self.key(for: url)
        queue.async {
            self.downloads[key] = nil
            if self.files[key]?.isComplete == false { self.files[key]?.pinned = false }
            self.save(key)
            self.scheduleNotify()
        }
    }

    /// Deletes a recording. One being played is only unpinned, so it can be evicted later.
    func delete(_ url: URL) {
        let key = Self.key(for: url)
        queue.async {
            self.downloads[key] = nil
            if self.inUse.contains(key) {
                self.files[key]?.pinned = false
                self.save(key)
            } else {
                self.remove(key)
            }
            self.scheduleNotify()
        }
    }

    /// Removes every recording saved while playing; downloads stay.
    func clearCache() {
        queue.async {
            for (key, state) in self.files where !state.pinned && !self.inUse.contains(key) { self.remove(key) }
            self.scheduleNotify()
        }
    }

    private func continueDownload(_ key: String) {
        guard let download = downloads[key] else { return }
        guard let state = files[key] else {
            ensure(key: key, url: download.url, chunk: 0, limit: Self.maxRun) { [weak self] error in
                self?.downloadStep(key, error: error)
            }
            return
        }
        if !state.pinned { files[key]?.pinned = true }
        guard let missing = (0 ..< state.chunkCount).first(where: { !state.chunks.contains($0) }) else {
            downloads[key] = nil
            files[key]?.pinned = true
            save(key)
            scheduleNotify()
            return
        }
        ensure(key: key, url: download.url, chunk: missing, limit: missing + Self.maxRun) { [weak self] error in
            self?.downloadStep(key, error: error)
        }
    }

    private func downloadStep(_ key: String, error: Error?) {
        guard downloads[key] != nil else { return }
        if error != nil {
            // Keep what was fetched; the download can be started again.
            downloads[key] = nil
            files[key]?.pinned = false
            save(key)
            scheduleNotify()
            return
        }
        scheduleNotify()
        continueDownload(key)
    }

    // MARK: Fetching chunks

    /// Calls `completion` once `chunk` is stored, fetching it (and following missing chunks up to
    /// `limit`) when it is not already stored or on its way.
    private func ensure(key: String, url: URL, chunk: Int, limit: Int, completion: @escaping (Error?) -> Void) {
        if files[key]?.chunks.contains(chunk) == true { return completion(nil) }
        if waiters[key]?[chunk] != nil {
            waiters[key]![chunk]!.append(completion)
            return
        }
        // The run: this chunk and the next ones that are neither stored nor being fetched.
        let state = files[key]
        var end = chunk + 1
        let last = min(limit, chunk + Self.maxRun, state?.chunkCount ?? .max)
        while end < last, state?.chunks.contains(end) != true, waiters[key]?[end] == nil { end += 1 }
        for index in chunk ..< end { waiters[key, default: [:]][index] = [] }
        waiters[key]![chunk]!.append(completion)

        var request = URLRequest(url: url)
        let first = chunk * CachedAudioState.chunkSize
        let lastByte = end * CachedAudioState.chunkSize - 1
        request.setValue("bytes=\(first)-\(state.map { min(lastByte, $0.length - 1) } ?? lastByte)", forHTTPHeaderField: "Range")
        if let etag = state?.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
        let task = session.dataTask(with: request)
        fetches[task.taskIdentifier] = Fetch(key: key, chunks: chunk ..< end, offset: first)
        task.resume()
    }

    /// The fetch's response: learns the recording's size, and starts over when the server's file changed.
    private func accept(_ response: URLResponse, for fetch: Fetch) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let total: Int
        switch http.statusCode {
        case 206:
            guard let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init) else { return false }
            total = range.total
            fetch.offset = range.first
        case 200:
            // The whole file: the server ignored the range, or the file changed since it was stored.
            total = Int(http.expectedContentLength)
            fetch.offset = 0
            guard total > 0 else { return false }
            if let state = files[fetch.key] {
                let pinned = state.pinned
                reset(fetch.key)
                files[fetch.key] = CachedAudioState(length: total, etag: etag)
                files[fetch.key]?.pinned = pinned || downloads[fetch.key] != nil
            }
        default:
            return false
        }
        var pinned = downloads[fetch.key] != nil
        if let state = files[fetch.key], state.length != total || (etag != nil && state.etag != nil && etag != state.etag) {
            pinned = pinned || state.pinned
            reset(fetch.key)
        }
        if files[fetch.key] == nil {
            files[fetch.key] = CachedAudioState(length: total, etag: etag)
            files[fetch.key]?.pinned = pinned
        }
        fetch.nextChunk = CachedAudioState.chunk(containing: fetch.offset)
        return handle(for: fetch.key) != nil
    }

    private func receive(_ data: Data, for fetch: Fetch) {
        guard let handle = handle(for: fetch.key), let state = files[fetch.key] else { return }
        do {
            try handle.seek(toOffset: UInt64(fetch.offset))
            try handle.write(contentsOf: data)
        } catch {
            return
        }
        fetch.offset += data.count
        var completed = 0
        while fetch.nextChunk < state.chunkCount, fetch.offset >= state.byteRange(ofChunk: fetch.nextChunk).upperBound {
            files[fetch.key]?.chunks.insert(fetch.nextChunk)
            let callbacks = waiters[fetch.key]?.removeValue(forKey: fetch.nextChunk) ?? []
            callbacks.forEach { $0(nil) }
            fetch.nextChunk += 1
            completed += 1
        }
        if completed > 0 {
            if fetch.nextChunk % 8 == 0 { save(fetch.key) }
            scheduleNotify()
        }
    }

    private func finish(_ fetch: Fetch, error: Error?) {
        // Chunks the fetch was meant to bring but did not.
        let failure = error ?? URLError(.badServerResponse)
        for index in fetch.chunks {
            guard let callbacks = waiters[fetch.key]?.removeValue(forKey: index) else { continue }
            if files[fetch.key]?.chunks.contains(index) == true {
                callbacks.forEach { $0(nil) }
            } else {
                callbacks.forEach { $0(failure) }
            }
        }
        if waiters[fetch.key]?.isEmpty == true { waiters[fetch.key] = nil }
        files[fetch.key]?.lastUsed = Date()
        save(fetch.key)
        evict()
        scheduleNotify()
    }

    // MARK: Storage

    private func directory(for key: String) -> URL {
        root.appending(path: key).deletingLastPathComponent()
    }

    private func dataURL(_ key: String) -> URL { root.appending(path: key + ".mp3") }
    private func stateURL(_ key: String) -> URL { root.appending(path: key + ".json") }

    private func handle(for key: String) -> FileHandle? {
        if let handle = handles[key] { return handle }
        let url = dataURL(key)
        let manager = FileManager.default
        try? manager.createDirectory(at: directory(for: key), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forUpdating: url)
        handles[key] = handle
        return handle
    }

    private func read(_ key: String, _ range: Range<Int>) -> Data? {
        guard let handle = handle(for: key) else { return nil }
        try? handle.seek(toOffset: UInt64(range.lowerBound))
        return try? handle.read(upToCount: range.count)
    }

    private func save(_ key: String) {
        guard let state = files[key], let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory(for: key), withIntermediateDirectories: true)
        try? data.write(to: stateURL(key), options: .atomic)
    }

    /// Forgets the stored chunks of a recording that no longer matches the server's file.
    private func reset(_ key: String) {
        try? handles[key]?.truncate(atOffset: 0)
        files[key] = nil
    }

    private func remove(_ key: String) {
        try? handles.removeValue(forKey: key)?.close()
        files[key] = nil
        try? FileManager.default.removeItem(at: dataURL(key))
        try? FileManager.default.removeItem(at: stateURL(key))
    }

    private func loadIndex() {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath), let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(CachedAudioState.self, from: data) else { continue }
            let key = String(path.dropFirst(rootPath.count).dropLast(".json".count))
            files[key] = state
        }
        scheduleNotify()
    }

    /// Recordings being read, fetched, or downloaded, which eviction leaves alone.
    private var inUse: Set<String> {
        Set(jobs.values.map(\.key)).union(fetches.values.map(\.key)).union(downloads.keys).union(playheads.keys)
    }

    private func evict() {
        for key in AudioCachePolicy.evictions(files, budget: budget, inUse: inUse) { remove(key) }
    }

    private func scheduleNotify() {
        guard !notifyScheduled, onChange != nil else { return }
        notifyScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) {
            self.notifyScheduled = false
            var progress: [String: Double] = [:]
            for key in self.downloads.keys { progress[key] = self.files[key]?.fractionStored ?? 0 }
            self.onChange?(Summary(files: self.files, downloading: progress))
        }
    }

    // MARK: Serving the player

    /// Confined to `queue`, like the rest of the cache.
    private final class Job: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        let key: String
        let url: URL
        let startOffset: Int
        var parked = false
        var cancelled = false
        var described = false

        init(request: AVAssetResourceLoadingRequest, key: String, url: URL) {
            self.request = request
            self.key = key
            self.url = url
            startOffset = Int(request.dataRequest?.requestedOffset ?? 0)
        }
    }

    private final class Fetch {
        let key: String
        let chunks: Range<Int>
        var offset: Int
        var nextChunk = 0

        init(key: String, chunks: Range<Int>, offset: Int) {
            self.key = key
            self.chunks = chunks
            self.offset = offset
        }
    }

    private struct Download {
        let url: URL
    }

    /// Answers one of the player's reads: the file's description, then its bytes as they become available.
    private func process(_ job: Job) {
        guard !job.cancelled else { return }
        let request = job.request
        guard let state = files[job.key] else {
            // The first fetch tells the recording's size.
            let chunk = CachedAudioState.chunk(containing: job.startOffset)
            ensure(key: job.key, url: job.url, chunk: chunk, limit: chunk + 1) { [weak self] error in
                self?.continueJob(job, error: error)
            }
            return
        }
        if !job.described, let information = request.contentInformationRequest {
            information.contentType = UTType.mp3.identifier
            information.contentLength = Int64(state.length)
            information.isByteRangeAccessSupported = true
            job.described = true
        }
        guard let dataRequest = request.dataRequest else { return complete(job, error: nil) }
        let end = dataRequest.requestsAllDataToEndOfResource
            ? state.length : min(Int(dataRequest.requestedOffset) + dataRequest.requestedLength, state.length)
        let offset = Int(dataRequest.currentOffset)
        guard offset < end else { return complete(job, error: nil) }
        let chunk = CachedAudioState.chunk(containing: offset)
        // Open-ended reads stop `readAhead` past the playhead (or where the read began) until it moves on,
        // for stored chunks too: the player keeps what it is given in memory, so giving it a whole stored
        // recording would hold all of it. Until the recording plays, two chunks.
        let windowEnd = playheads[job.key].map { CachedAudioState.chunk(containing: max($0, job.startOffset) + Self.readAhead) + 1 }
            ?? CachedAudioState.chunk(containing: job.startOffset) + 2
        if dataRequest.requestsAllDataToEndOfResource, chunk >= windowEnd {
            job.parked = true
            return
        }
        if state.chunks.contains(chunk) {
            files[job.key]?.lastUsed = Date()
            guard let data = read(job.key, offset ..< min(state.byteRange(ofChunk: chunk).upperBound, end)), !data.isEmpty else {
                return complete(job, error: URLError(.cannotOpenFile))
            }
            dataRequest.respond(with: data)
            queue.async { self.process(job) }
            return
        }
        let limit = dataRequest.requestsAllDataToEndOfResource ? windowEnd : CachedAudioState.chunk(containing: end - 1) + 1
        ensure(key: job.key, url: job.url, chunk: chunk, limit: limit) { [weak self] error in
            self?.continueJob(job, error: error)
        }
    }

    private func continueJob(_ job: Job, error: Error?) {
        guard !job.cancelled else { return }
        if let error { return complete(job, error: error) }
        process(job)
    }

    private func complete(_ job: Job, error: Error?) {
        jobs[ObjectIdentifier(job.request)] = nil
        guard !job.cancelled else { return }
        if let error { job.request.finishLoading(with: error) } else { job.request.finishLoading() }
    }
}

extension AudioCache: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        let remote = Self.remoteURL(for: url)
        let job = Job(request: loadingRequest, key: Self.key(for: remote), url: remote)
        jobs[ObjectIdentifier(loadingRequest)] = job
        process(job)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        jobs.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancelled = true
    }
}

extension AudioCache: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let fetch = fetches[dataTask.taskIdentifier], accept(response, for: fetch) else {
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let fetch = fetches[dataTask.taskIdentifier] else { return }
        receive(data, for: fetch)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let fetch = fetches.removeValue(forKey: task.taskIdentifier) else { return }
        finish(fetch, error: error)
    }
}

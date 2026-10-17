import CryptoKit
import Foundation
import MushafRendering
import Observation
import QuranStore

/// The page fonts of a layout drawn with one font per page (QCF V2). They are not bundled: the first
/// time the layout is shown they are downloaded once into Application Support and checked against
/// the sizes and SHA-256 hashes listed in the database. Until every page is present, the reader
/// draws the layout with its fallback font.
@MainActor
@Observable
final class PageFontStore {
    enum Status: Equatable {
        case missing
        case downloading(fraction: Double)
        case failed(String)
        case ready
    }

    let layout: LayoutInfo
    private(set) var status: Status = .missing

    @ObservationIgnored private let files: [PageFontFile]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let cache = FontCache()
    @ObservationIgnored private var download: Task<Void, Never>?

    init?(layout: LayoutInfo, store: QuranStore, root: URL = PageFontStore.defaultRoot) {
        guard layout.pageFonts != nil, let files = try? store.pageFontFiles(of: layout), files.count == layout.pageCount else {
            return nil
        }
        self.layout = layout
        self.files = files
        directory = root.appendingPathComponent(layout.id, isDirectory: true)
        // A file is trusted once it has its expected size: downloads are hashed before they are moved into place.
        if files.allSatisfy(isPresent) { status = .ready }
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Surabar/PageFonts", isDirectory: true)
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    // MARK: Fonts

    /// The glyph fonts for a page, or nil until every page font is present.
    func glyphFonts(page: Int) -> GlyphFonts? {
        guard status == .ready, let pageFont = font(page), let first = font(1) else { return nil }
        prefetch(around: page)
        return GlyphFonts(page: pageFont, basmallah: first)
    }

    private func font(_ page: Int) -> MushafFont? {
        guard files.indices.contains(page - 1) else { return nil }
        return cache.font(at: url(of: files[page - 1]))
    }

    /// Loads the neighbouring pages' fonts in the background so page turns stay fast.
    private func prefetch(around page: Int) {
        let urls = [page - 1, page + 1].filter { files.indices.contains($0 - 1) }.map { url(of: files[$0 - 1]) }
        let cache = cache
        Task.detached(priority: .utility) {
            for url in urls { _ = cache.font(at: url) }
        }
    }

    // MARK: Downloading

    /// Starts or resumes the one-time download. Files already present are kept.
    func download(using session: URLSession = .shared) {
        guard status != .ready, download == nil else { return }
        let pending = files.filter { !isPresent($0) }
        let total = Double(totalBytes)
        var done = Double(totalBytes - pending.reduce(0) { $0 + $1.bytes })
        status = .downloading(fraction: done / total)
        let directory = directory
        let layout = layout
        download = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await withThrowingTaskGroup(of: Int.self) { group in
                    var queue = pending[...]
                    func next() {
                        guard let file = queue.popFirst() else { return }
                        group.addTask { try await Self.fetch(file, layout: layout, into: directory, session: session) }
                    }
                    for _ in 0 ..< 6 { next() }
                    for try await bytes in group {
                        done += Double(bytes)
                        self?.status = .downloading(fraction: min(done / total, 1))
                        next()
                    }
                }
                self?.status = .ready
            } catch is CancellationError {
                self?.status = .missing
            } catch {
                self?.status = .failed((error as? PageFontError)?.description ?? error.localizedDescription)
            }
            self?.download = nil
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// Deletes the downloaded fonts; the layout falls back to its bundled font.
    func deleteDownloads() {
        download?.cancel()
        try? FileManager.default.removeItem(at: directory)
        cache.removeAll()
        status = .missing
    }

    private nonisolated static func fetch(_ file: PageFontFile, layout: LayoutInfo, into directory: URL,
                                          session: URLSession) async throws -> Int {
        guard let url = layout.pageFonts?.url(page: file.page) else { throw PageFontError.badURL(file.page) }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PageFontError.http(page: file.page, status: http.statusCode)
        }
        let data = try Data(contentsOf: temporary)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == file.bytes, digest == file.sha256 else { throw PageFontError.mismatch(page: file.page) }
        let destination = directory.appendingPathComponent(file.file)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return file.bytes
    }

    private func url(of file: PageFontFile) -> URL {
        directory.appendingPathComponent(file.file)
    }

    private func isPresent(_ file: PageFontFile) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url(of: file).path)[.size] as? Int) ?? nil
        return size == file.bytes
    }
}

enum PageFontError: Error, CustomStringConvertible {
    case badURL(Int)
    case http(page: Int, status: Int)
    case mismatch(page: Int)

    var description: String {
        switch self {
        case .badURL(let page): "No download address for page \(page)."
        case .http(let page, let status): "The server returned an error (\(status)) for page \(page)."
        case .mismatch(let page): "Page \(page)'s font did not match its expected checksum."
        }
    }
}

/// Loaded page fonts, shared with background prefetching. Keeps the most recently used few.
private final class FontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fonts: [URL: MushafFont] = [:]
    private var order: [URL] = []
    private let limit = 8

    func font(at url: URL) -> MushafFont? {
        lock.lock()
        if let font = fonts[url] {
            order.removeAll { $0 == url }
            order.append(url)
            lock.unlock()
            return font
        }
        lock.unlock()
        guard let font = try? MushafFont(url: url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        fonts[url] = font
        order.append(url)
        while order.count > limit { fonts[order.removeFirst()] = nil }
        return font
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        fonts.removeAll()
        order.removeAll()
    }
}

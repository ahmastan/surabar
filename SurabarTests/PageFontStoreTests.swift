import Foundation
import MushafRendering
import QuranStore
import Testing
@testable import Surabar

/// These use the real bundled database and the owner's local copy of the QCF V2 page fonts
/// (tools/data/raw), served through a stub URL protocol instead of the network.
private let library = try? QuranLibrary.loadBundled().get()
private let sourceFonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tools/data/raw/uthmani/qpc-v2-woff2-2026-10-16")
private let available = library != nil && FileManager.default.fileExists(atPath: sourceFonts.appendingPathComponent("p1.woff2").path)

/// Answers page font requests from the local copy; can corrupt one page or count requests.
private final class LocalFontProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var corruptPage: Int?
    nonisolated(unsafe) static var requests = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url!.lastPathComponent
        Self.lock.withLock { Self.requests += 1 }
        var data = (try? Data(contentsOf: sourceFonts.appendingPathComponent(name))) ?? Data()
        if let page = Self.corruptPage, name == "p\(page).woff2", !data.isEmpty { data[data.count / 2] ^= 0xFF }
        let response = HTTPURLResponse(url: request.url!, statusCode: data.isEmpty ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized, .enabled(if: available, "Needs the bundled data and the local QCF V2 font downloads"))
struct PageFontStoreTests {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalFontProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private func makeStore() throws -> (PageFontStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-fonts-\(UUID().uuidString)")
        let layout = try library!.store.layout("uthmani")
        return (try #require(PageFontStore(layout: layout, store: library!.store, root: root)), root)
    }

    private func waitWhileDownloading(_ store: PageFontStore) async {
        for _ in 0 ..< 600 {
            if case .downloading = store.status { try? await Task.sleep(for: .milliseconds(50)) } else { return }
        }
    }

    @Test func downloadsChecksAndUsesEveryPageFont() async throws {
        LocalFontProtocol.corruptPage = nil
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.status == .missing)
        #expect(store.glyphFonts(page: 3) == nil)
        store.download(using: session)
        await waitWhileDownloading(store)
        #expect(store.status == .ready)
        let fonts = try #require(store.glyphFonts(page: 3))
        #expect(fonts.page.postScriptName == "QCF2003")
        #expect(fonts.basmallah.postScriptName == "QCF2001")

        // A new store over the same folder finds the fonts without downloading again.
        let layout = try library!.store.layout("uthmani")
        #expect(PageFontStore(layout: layout, store: library!.store, root: root)?.status == .ready)
    }

    @Test func aCorruptFileFailsAndARetryResumes() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        LocalFontProtocol.corruptPage = 300
        store.download(using: session)
        await waitWhileDownloading(store)
        guard case .failed(let message) = store.status else {
            Issue.record("expected a failure, got \(store.status)")
            return
        }
        #expect(message.contains("300"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("uthmani/p300.woff2").path))

        LocalFontProtocol.corruptPage = nil
        LocalFontProtocol.requests = 0
        store.download(using: session)
        await waitWhileDownloading(store)
        #expect(store.status == .ready)
        // Files that were already checked are kept, so the retry fetches fewer than all 604.
        #expect(LocalFontProtocol.requests < 604)

        store.deleteDownloads()
        #expect(store.status == .missing)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("uthmani").path))
    }
}

@MainActor
@Suite(.enabled(if: library != nil, "Run tools/prepare_app_resources.py to bundle the Quran data"))
struct PageFontFallbackTests {
    @Test func uthmaniUsesItsFallbackFontUntilThePageFontsArePresent() throws {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = ReaderModel(state: AppState(defaults: defaults), library: .success(library!))
        let fonts = try #require(model.currentPageFonts)
        guard fonts.status != .ready else { return }  // Fonts already downloaded on this Mac.
        #expect(!model.usesPageFonts)
        let layout = try #require(model.pageLayout(fitting: CGSize(width: 440, height: 2000)))
        #expect(layout.diagnostics.missingGlyphs.isEmpty)
        #expect(layout.diagnostics.overflowingLines.isEmpty)
    }
}

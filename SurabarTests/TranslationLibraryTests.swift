import Foundation
import MushafRendering
import QuranStore
import Testing
@testable import Surabar

/// QuranEnc stub: the catalogue lists the bundled translation (at a chosen version) and a French one;
/// both downloads return the bundled file, or a broken one.
private final class QuranEncStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var saheehVersion = "1.1.2"
    nonisolated(unsafe) static var brokenDownloads = false
    nonisolated(unsafe) static var downloads = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = Data()
        if url.path.hasPrefix("/api/v1/translations/list") {
            body = Data("""
                {"translations":[
                 {"key":"english_saheeh","direction":"ltr","language_iso_code":"en","version":"\(Self.saheehVersion)","last_update":2,
                  "title":"English Translation - Noor International Center","description":"Issued by Noor International Center."},
                 {"key":"french_test","direction":"ltr","language_iso_code":"fr","version":"1.0.0","last_update":1,
                  "title":"French Translation - Test","description":"Test."}]}
                """.utf8)
        } else if url.path.hasPrefix("/downloads/sqlite/") {
            Self.downloads += 1
            body = Self.brokenDownloads ? Data("not a database".utf8)
                : (try? Data(contentsOf: Bundle.main.url(forResource: "translation", withExtension: "sqlite")!)) ?? Data()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized, .enabled(if: Bundle.main.url(forResource: "translation", withExtension: "sqlite") != nil,
                             "Run tools/prepare_app_resources.py to bundle the translation"))
struct TranslationLibraryTests {
    private func makeLibrary() -> (TranslationLibrary, AppState, URL) {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let state = AppState(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory.appending(path: "surabar-translations-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuranEncStub.self]
        return (TranslationLibrary(state: state, folder: folder, session: URLSession(configuration: configuration)), state, folder)
    }

    private func waitWhileDownloading(_ library: TranslationLibrary, _ key: String) async {
        for _ in 0 ..< 250 where library.status(of: key) == .downloading {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func theBundledTranslationIsTheDefault() {
        let (library, _, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = library.current?.info
        #expect(info?.key == "english_saheeh" && info?.name == "Saheeh International" && info?.version == "1.1.2")
        #expect(library.current?.text(for: AyahKey(surah: 112, ayah: 1))?.contains("He is Allāh") == true)
        #expect(library.current?.footnotes(for: AyahKey(surah: 2, ayah: 255))?.contains("[98]") == true)
    }

    @Test func downloadingShowsATranslationAndDeletingFallsBack() async {
        QuranEncStub.saheehVersion = "1.1.2"
        QuranEncStub.brokenDownloads = false
        let (library, state, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await library.refresh(force: true)
        #expect(library.catalog.map(\.key) == ["english_saheeh", "french_test"])
        let french = library.catalog[1]
        #expect(library.status(of: french.key) == .available)
        library.use(french)
        await waitWhileDownloading(library, french.key)
        #expect(library.status(of: french.key) == .installed)
        #expect(state.translationKey == "french_test" && library.current?.info.key == "french_test")
        library.delete(french.key)
        #expect(state.translationKey == nil && library.current?.info.key == "english_saheeh")
    }

    @Test func aNewerVersionReplacesTheBundledOne() async {
        QuranEncStub.saheehVersion = "1.1.3"
        QuranEncStub.brokenDownloads = false
        let (library, _, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await library.refresh(force: true)
        await waitWhileDownloading(library, "english_saheeh")
        #expect(library.current?.info.version == "1.1.3", "the update is shown")
        #expect(library.current?.info.name == "Saheeh International")
        QuranEncStub.saheehVersion = "1.1.2"
    }

    @Test func aBrokenDownloadChangesNothing() async {
        QuranEncStub.brokenDownloads = true
        let (library, state, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await library.refresh(force: true)
        library.use(library.catalog[1])
        await waitWhileDownloading(library, "french_test")
        #expect(library.status(of: "french_test") == .failed("Couldn't download Test"))
        #expect(state.translationKey == nil && library.current?.info.key == "english_saheeh")
        QuranEncStub.brokenDownloads = false
    }
}

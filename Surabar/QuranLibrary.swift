import Foundation
import MushafRendering
import QuranStore

/// The bundled, read-only Quran data: database, one font per layout, and the English translation.
final class QuranLibrary: Sendable {
    let store: QuranStore
    let fonts: [String: MushafFont]
    let translation: Translation?

    private init(store: QuranStore, fonts: [String: MushafFont], translation: Translation?) {
        self.store = store
        self.fonts = fonts
        self.translation = translation
    }

    /// Loads the files tools/prepare_app_resources.py places in Surabar/Resources/Bundled.
    static func loadBundled(from bundle: Bundle = .main) -> Result<QuranLibrary, QuranStoreError> {
        guard let database = bundle.url(forResource: "quran", withExtension: "sqlite") else {
            return .failure(QuranStoreError("The Quran data is not bundled. Run tools/prepare_app_resources.py, then build again."))
        }
        do {
            let store = try QuranStore(url: database)
            var fonts: [String: MushafFont] = [:]
            for layout in store.layouts {
                let name = layout.fontFile as NSString
                guard let url = bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension) else {
                    throw QuranStoreError("The \(layout.name) font (\(layout.fontFile)) is not bundled.")
                }
                fonts[layout.id] = try MushafFont(url: url)
            }
            let translation = bundle.url(forResource: "translation-en-sahih", withExtension: "json")
                .flatMap { try? Translation(url: $0, name: "Saheeh International") }
            return .success(QuranLibrary(store: store, fonts: fonts, translation: translation))
        } catch let error as QuranStoreError {
            return .failure(error)
        } catch {
            return .failure(QuranStoreError(String(describing: error)))
        }
    }
}

/// A translation keyed by "surah:ayah", read from QUL's simple JSON export.
struct Translation: Sendable {
    let name: String
    private let texts: [String: String]

    init(url: URL, name: String) throws {
        struct Entry: Decodable { let t: String }
        texts = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url)).mapValues(\.t)
        self.name = name
    }

    func text(for ayah: AyahKey) -> String? { texts[ayah.description] }
}

import Foundation
import MushafRendering
import QuranStore

/// The bundled, read-only Quran data: database and one font per layout. Translations are in `TranslationLibrary`.
final class QuranLibrary: Sendable {
    let store: QuranStore
    let fonts: [String: MushafFont]

    private init(store: QuranStore, fonts: [String: MushafFont]) {
        self.store = store
        self.fonts = fonts
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
            return .success(QuranLibrary(store: store, fonts: fonts))
        } catch let error as QuranStoreError {
            return .failure(error)
        } catch {
            return .failure(QuranStoreError(String(describing: error)))
        }
    }
}

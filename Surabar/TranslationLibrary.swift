import Foundation
import MushafRendering
import Observation
import QuranStore

/// Translations from QuranEnc.com: the bundled default, the catalogue, and downloaded translations in
/// Application Support. One translation is shown at a time. QuranEnc's terms ask that translations be
/// kept up to date, so installed ones (and the bundled one) update when the catalogue lists a newer version.
@MainActor
@Observable
final class TranslationLibrary {
    enum Status: Equatable {
        case available
        case downloading
        case installed
        case failed(String)
    }

    /// The translation shown, or nil when none could be loaded.
    private(set) var current: TranslationDatabase?
    /// QuranEnc's catalogue, newest fetch or the cached one.
    private(set) var catalog: [TranslationInfo] = []
    private(set) var catalogError: String?
    private(set) var installed: [String: TranslationInfo] = [:]
    private(set) var statuses: [String: Status] = [:]

    let bundled: TranslationInfo?
    @ObservationIgnored private let bundledURL: URL?
    @ObservationIgnored private let state: AppState
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var lastCatalogFetch: Date?

    static let catalogURL = URL(string: "https://quranenc.com/api/v1/translations/list")!

    init(state: AppState, bundle: Bundle = .main,
         folder: URL = URL.applicationSupportDirectory.appending(path: "Surabar/Translations"), session: URLSession = .shared) {
        self.state = state
        self.folder = folder
        self.session = session
        bundledURL = bundle.url(forResource: "translation", withExtension: "sqlite")
        bundled = bundle.url(forResource: "translation", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(TranslationInfo.self, from: $0) }
        loadInstalled()
        if let data = try? Data(contentsOf: folder.appending(path: "catalog.json")),
           let cached = try? JSONDecoder().decode([TranslationInfo].self, from: data) {
            catalog = cached
        }
        loadCurrent()
    }

    /// The key of the translation shown: the chosen one, or the bundled default.
    var currentKey: String? { state.translationKey ?? bundled?.key }

    func status(of key: String) -> Status {
        if let status = statuses[key], status != .installed { return status }
        return installed[key] != nil || key == bundled?.key ? .installed : .available
    }

    // MARK: Choosing

    /// Shows a translation, downloading it first when needed.
    func use(_ info: TranslationInfo) {
        if status(of: info.key) == .installed {
            state.translationKey = info.key == bundled?.key && installed[info.key] == nil ? nil : info.key
            loadCurrent()
        } else {
            download(info, thenUse: true)
        }
    }

    /// Removes a downloaded translation; the bundled default stays. Showing it falls back to the default.
    func delete(_ key: String) {
        try? FileManager.default.removeItem(at: databaseURL(key))
        try? FileManager.default.removeItem(at: infoURL(key))
        installed[key] = nil
        statuses[key] = nil
        if state.translationKey == key {
            state.translationKey = nil
        }
        loadCurrent()
    }

    // MARK: Catalogue and updates

    /// Fetches QuranEnc's catalogue (at most every few hours unless forced), then updates installed
    /// translations that have a newer version.
    func refresh(force: Bool = false) async {
        if !force, let last = lastCatalogFetch, Date().timeIntervalSince(last) < 6 * 3600 { return }
        struct List: Decodable {
            struct Entry: Decodable {
                let key: String
                let direction: String
                let language_iso_code: String
                let version: String
                let last_update: Int
                let title: String
                let description: String
            }
            let translations: [Entry]
        }
        do {
            let (data, response) = try await session.data(from: Self.catalogURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let list = try JSONDecoder().decode(List.self, from: data)
            catalog = list.translations.map { entry in
                TranslationInfo(key: entry.key, title: entry.title, displayName: entry.key == bundled?.key ? bundled?.displayName : nil,
                                description: entry.description, language: entry.language_iso_code, direction: entry.direction,
                                version: entry.version, lastUpdate: entry.last_update)
            }
            catalogError = nil
            lastCatalogFetch = Date()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(catalog).write(to: folder.appending(path: "catalog.json"), options: .atomic)
        } catch {
            catalogError = "Couldn't load the list of translations. Check your connection."
            return
        }
        for latest in catalog {
            let have = installed[latest.key] ?? (latest.key == bundled?.key ? bundled : nil)
            if let have, have.isOlder(than: latest), statuses[latest.key] != .downloading {
                download(latest, thenUse: false)
            }
        }
    }

    // MARK: Downloading

    private func download(_ info: TranslationInfo, thenUse: Bool) {
        statuses[info.key] = .downloading
        let destination = databaseURL(info.key)
        let infoDestination = infoURL(info.key)
        let folder = folder
        let session = session
        Task {
            do {
                let url = URL(string: "https://quranenc.com/downloads/sqlite/\(info.key).sqlite")!
                let (temporary, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                // Check the file before it replaces anything.
                _ = try TranslationDatabase(url: temporary, info: info)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                try JSONEncoder().encode(info).write(to: infoDestination, options: .atomic)
                installed[info.key] = info
                statuses[info.key] = .installed
                if thenUse { state.translationKey = info.key }
                if thenUse || currentKey == info.key { loadCurrent() }
            } catch {
                statuses[info.key] = .failed("Couldn't download \(info.name)")
            }
        }
    }

    // MARK: Storage

    private func databaseURL(_ key: String) -> URL { folder.appending(path: "\(key).sqlite") }
    private func infoURL(_ key: String) -> URL { folder.appending(path: "\(key).json") }

    private func loadInstalled() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "catalog.json" {
            guard let data = try? Data(contentsOf: file), let info = try? JSONDecoder().decode(TranslationInfo.self, from: data),
                  FileManager.default.fileExists(atPath: databaseURL(info.key).path) else { continue }
            installed[info.key] = info
        }
    }

    /// Loads the shown translation: a download (including a newer copy of the bundled one), else the bundled file.
    private func loadCurrent() {
        guard let key = currentKey else { current = nil; return }
        if let info = installed[key], let translation = try? TranslationDatabase(url: databaseURL(key), info: info) {
            current = translation
        } else if key == bundled?.key, let bundled, let bundledURL {
            current = try? TranslationDatabase(url: bundledURL, info: bundled)
        } else {
            // The chosen translation is gone: fall back to the default.
            state.translationKey = nil
            current = bundled.flatMap { info in bundledURL.flatMap { try? TranslationDatabase(url: $0, info: info) } }
        }
    }
}

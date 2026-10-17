import QuranStore
import SwiftUI

/// Settings › Reading › Translation: QuranEnc.com's translations by language, to download and show.
struct TranslationsView: View {
    let translations: TranslationLibrary
    let state: AppState
    let palette: ReaderPalette
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { state.showsTranslations = false } label: {
                    Label("Reading", systemImage: "chevron.left").font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                Spacer()
                TextField("Search translations", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Text("Translations of the meanings from QuranEnc.com, shown unmodified with their publishers' credits. "
                 + "Downloaded translations update when QuranEnc publishes a new version.")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = translations.catalogError, translations.catalog.isEmpty {
                HStack {
                    Text(error).font(.callout).foregroundStyle(palette.secondary)
                    Button("Retry") { Task { await translations.refresh(force: true) } }
                }
            } else if translations.catalog.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ForEach(languages, id: \.code) { language in
                SettingsGroup(title: language.name, palette: palette) {
                    ForEach(Array(language.entries.enumerated()), id: \.element.key) { index, info in
                        if index > 0 { Divider() }
                        row(info)
                    }
                }
            }
        }
        .task { await translations.refresh() }
    }

    private func row(_ info: TranslationInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                Text(info.description).font(.caption).foregroundStyle(palette.secondary).lineLimit(2)
                Text("Version \(info.version)").font(.caption2).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 8)
            control(info)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func control(_ info: TranslationInfo) -> some View {
        let inUse = translations.currentKey == info.key
        switch translations.status(of: info.key) {
        case .downloading:
            ProgressView().controlSize(.small).help("Downloading")
        case .failed(let message):
            Button("Retry") { translations.use(info) }.help(message)
        case .available:
            Button("Get") { translations.use(info) }.help("Download and show this translation")
        case .installed:
            HStack(spacing: 6) {
                if inUse {
                    Label("In use", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                } else {
                    Button("Use") { translations.use(info) }
                }
                if info.key != translations.bundled?.key {
                    Menu {
                        Button("Delete Download", role: .destructive) { translations.delete(info.key) }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(palette.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
        }
    }

    /// Languages by name, the one in use first; within each, translations by name.
    private var languages: [(code: String, name: String, entries: [TranslationInfo])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = (translations.catalog.isEmpty ? [translations.bundled].compactMap { $0 } : translations.catalog).filter { info in
            needle.isEmpty || info.title.lowercased().contains(needle) || info.description.lowercased().contains(needle)
                || languageName(info.language).lowercased().contains(needle)
        }
        let currentLanguage = translations.current?.info.language
        return Dictionary(grouping: entries, by: \.language)
            .map { (code: $0.key, name: languageName($0.key), entries: $0.value.sorted { $0.name < $1.name }) }
            .sorted { ($0.code == currentLanguage ? 0 : 1, $0.name) < ($1.code == currentLanguage ? 0 : 1, $1.name) }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

import MushafRendering
import QuranStore
import SwiftUI

struct ReaderActions {
    let detach: () -> Void
    let attach: () -> Void
    let openSettings: () -> Void
}

/// The reader: navigation header, mushaf page with its footer, the optional translation strip, and the player.
struct ReaderView: View {
    let state: AppState
    let model: ReaderModel
    let player: RecitationPlayer?
    let actions: ReaderActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.loadError {
                missingData(error)
            } else {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        MushafPageView(model: model, theme: state.theme)
                            .accessibilityLabel("Mushaf page \(model.pageNumber)")
                        footer
                    }
                    .background(palette.page)
                    overlay
                }
                if state.showTranslation {
                    Divider()
                    TranslationStrip(model: model, playing: player?.isActive ?? false, palette: palette)
                }
                if let player {
                    Divider()
                    PlayerView(player: player, model: model, palette: palette)
                }
            }
        }
        .background(palette.chrome)
        .foregroundStyle(palette.ink)
        .animation(.easeOut(duration: 0.12), value: model.overlay)
    }

    private var palette: ReaderPalette { ReaderPalette(theme: state.theme) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Button { toggle(.surahPicker) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentSurah?.nameSimple ?? "Surabar").font(.headline).lineLimit(1)
                        if let surah = model.currentSurah, let info = model.pageInfo {
                            Text("Surah \(surah.number) · Juz \(info.juz)").font(.caption).foregroundStyle(palette.secondary)
                        }
                    }
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(palette.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.library == nil)
            .help("Go to a surah or juz")
            .accessibilityLabel("Go to a surah or juz. Current surah \(model.currentSurah?.nameSimple ?? "")")

            Spacer(minLength: 6)

            if let store = model.store, store.layouts.count > 1 {
                Button(action: model.toggleScript) {
                    Text(scriptName(model.state.script))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().strokeBorder(palette.secondary.opacity(0.4)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch script; the selected ayah stays in view")
                .accessibilityLabel("Script: \(scriptName(model.state.script)). Switch script")
            }
            headerButton("Jump to ayah or page (⌘L)", symbol: "magnifyingglass") { toggle(.jump) }
                .disabled(model.library == nil)
            if state.isDetached {
                headerButton("Return to menu bar", symbol: "menubar.arrow.up.rectangle", action: actions.attach)
            } else {
                headerButton("Detach window", symbol: "macwindow.on.rectangle", action: actions.detach)
            }
            headerButton("Settings (⌘,)", symbol: "gearshape", action: actions.openSettings)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: ReaderLayout.headerHeight)
    }

    private func headerButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggle(_ overlay: ReaderModel.Overlay) {
        model.overlay = model.overlay == overlay ? nil : overlay
    }

    private func scriptName(_ id: String) -> String {
        id == "indopak" ? "IndoPak" : "Uthmani"
    }

    // MARK: Page footer

    private var footer: some View {
        HStack {
            pageButton("Next page (←)", symbol: "chevron.left", disabled: model.pageNumber >= (model.layout?.pageCount ?? 1)) {
                model.turnPage(1)
            }
            Spacer()
            if let info = model.pageInfo, let layout = model.layout {
                Text("Page \(info.number) of \(layout.pageCount) · Juz \(info.juz) · Hizb \(info.hizb)")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .monospacedDigit()
            }
            Spacer()
            pageButton("Previous page (→)", symbol: "chevron.right", disabled: model.pageNumber <= 1) {
                model.turnPage(-1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ReaderLayout.footerHeight)
    }

    private func pageButton(_ label: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Overlays and states

    @ViewBuilder private var overlay: some View {
        switch model.overlay {
        case .surahPicker:
            SurahPicker(model: model, palette: palette)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .jump:
            JumpBox(model: model, palette: palette)
                .padding(10)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case nil:
            EmptyView()
        }
    }

    private func missingData(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light))
            Text("Quran data unavailable").font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondary)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The selected ayah's translation, scrolling when longer than three lines.
struct TranslationStrip: View {
    let model: ReaderModel
    /// While recitation plays, the selection follows the recited ayah.
    let playing: Bool
    let palette: ReaderPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.state.selectedAyah.description).font(.caption.weight(.bold)).foregroundStyle(palette.accent)
                Text(playing ? "Playing" : "Selected").font(.caption).foregroundStyle(palette.secondary)
                Spacer()
                Text(model.library?.translation?.name ?? "").font(.caption).foregroundStyle(palette.secondary)
            }
            ScrollView(.vertical) {
                Text(model.selectedTranslation ?? "No bundled translation.")
                    .font(.callout)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ReaderLayout.translationTextHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: ReaderLayout.translationHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Translation of ayah \(model.state.selectedAyah.description)")
    }
}

/// Theme colours. System, Light, and Dark follow the window appearance; Sepia uses fixed colours.
struct ReaderPalette {
    let theme: ReaderTheme

    var chrome: Color { theme == .sepia ? Color(red: 0.933, green: 0.894, blue: 0.812) : Color(nsColor: .windowBackgroundColor) }
    var page: Color { theme == .sepia ? Color(red: 0.973, green: 0.941, blue: 0.871) : Color(nsColor: .textBackgroundColor) }
    var ink: Color { theme == .sepia ? Color(red: 0.18, green: 0.141, blue: 0.086) : .primary }
    var secondary: Color { theme == .sepia ? Color(red: 0.416, green: 0.353, blue: 0.259) : .secondary }
    var accent: Color { theme == .sepia ? Color(red: 0.478, green: 0.306, blue: 0.114) : .accentColor }
}

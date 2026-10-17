import MushafRendering
import QuranStore
import SwiftUI

struct ReaderActions {
    let detach: () -> Void
    let attach: () -> Void
    let editCustomAccent: () -> Void
}

/// The reader: navigation header, then either the mushaf page with its footer, the optional translation
/// strip, and the player ("Quran + player"), or the player alone ("Player only"). Settings replace it in place.
struct ReaderView: View {
    let state: AppState
    let model: ReaderModel
    let player: RecitationPlayer?
    let actions: ReaderActions

    var body: some View {
        VStack(spacing: 0) {
            if state.isShowingSettings {
                SettingsView(state: state, model: model, palette: palette, editCustomAccent: actions.editCustomAccent)
            } else {
                header
                Divider()
                if let error = model.loadError {
                    missingData(error)
                } else if state.viewMode == .playerOnly {
                    if let player { PlayerView(player: player, model: model, palette: palette) }
                    Spacer(minLength: 0)
                } else {
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            MushafPageView(model: model, theme: state.theme, accent: palette.accentColor)
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
        }
        .background(palette.chrome)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .animation(.easeOut(duration: 0.12), value: model.overlay)
        // The first time a layout with page fonts is shown, fetch them once.
        .task(id: model.state.script) { model.preparePageFonts() }
    }

    private var palette: ReaderPalette { ReaderPalette(state: state) }

    /// In "Player only" mode there is no page to cover, so the surah picker and jump box open as popovers.
    private func popoverBinding(_ overlay: ReaderModel.Overlay) -> Binding<Bool> {
        Binding(get: { state.viewMode == .playerOnly && model.overlay == overlay },
                set: { if !$0, model.overlay == overlay { model.overlay = nil } })
    }

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
            .popover(isPresented: popoverBinding(.surahPicker), arrowEdge: .bottom) {
                SurahPicker(model: model, palette: palette).frame(width: 300, height: 380)
            }

            Spacer(minLength: 6)

            headerButton("Jump to ayah or page (⌘L)", symbol: "magnifyingglass") { toggle(.jump) }
                .disabled(model.library == nil)
                .popover(isPresented: popoverBinding(.jump), arrowEdge: .bottom) {
                    JumpBox(model: model, palette: palette, framed: false).frame(width: 300)
                }
            if state.isDetached {
                headerButton("Return to menu bar", symbol: "menubar.arrow.up.rectangle", action: actions.attach)
            } else {
                headerButton("Detach window", symbol: "macwindow.on.rectangle", action: actions.detach)
            }
            headerButton("Settings (⌘,)", symbol: "gearshape") {
                model.overlay = nil
                state.isShowingSettings = true
            }
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

    // MARK: Page footer

    private var footer: some View {
        HStack {
            pageButton("Next page (←)", symbol: "chevron.left", disabled: model.pageNumber >= (model.layout?.pageCount ?? 1)) {
                model.turnPage(1)
            }
            Spacer()
            if let fonts = model.currentPageFonts, fonts.status != .ready, fonts.status != .missing {
                PageFontStatus(fonts: fonts, palette: palette)
            } else if let info = model.pageInfo, let layout = model.layout {
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
        switch state.viewMode == .playerOnly ? nil : model.overlay {
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

/// Progress of the one-time page font download, or a retry after a failure, shown in the page footer.
struct PageFontStatus: View {
    let fonts: PageFontStore
    let palette: ReaderPalette

    var body: some View {
        Group {
            switch fonts.status {
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 60).tint(palette.accent)
                    Text("Downloading mushaf pages · \(Int(fraction * 100))%").font(.caption).monospacedDigit()
                        .foregroundStyle(palette.secondary)
                }
                .help("A one-time download of \(ByteCountFormatter.string(fromByteCount: Int64(fonts.totalBytes), countStyle: .file)). "
                      + "The page is shown with the standard font until it finishes.")
            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Mushaf pages couldn't download").font(.caption).foregroundStyle(palette.secondary)
                    Button("Retry") { fonts.download() }.buttonStyle(.link).font(.caption.weight(.semibold))
                }
                .help(message)
            case .missing, .ready:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
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

import MushafRendering
import QuranStore
import SwiftUI

struct ReaderActions {
    let detach: () -> Void
    let attach: () -> Void
    let editCustomAccent: () -> Void
    let exportAnnotations: () -> Void
    let importAnnotations: () -> Void
}

/// The reader: navigation header, then either the mushaf page with its footer, the optional translation
/// strip, and the player ("Quran + player"), or the player alone ("Player only"). Settings replace it in place.
struct ReaderView: View {
    let state: AppState
    let model: ReaderModel
    let player: RecitationPlayer?
    let downloads: DownloadCenter?
    let actions: ReaderActions

    var body: some View {
        VStack(spacing: 0) {
            if state.isShowingSettings {
                SettingsView(state: state, model: model, player: player, downloads: downloads, palette: palette,
                             actions: actions)
            } else {
                header
                if let error = model.loadError {
                    missingData(error)
                } else if state.viewMode == .playerOnly {
                    if let player {
                        NowPlayingCard(player: player, model: model, palette: palette)
                        PlayerView(player: player, model: model, palette: palette)
                    }
                    Spacer(minLength: 0)
                } else {
                    // The page is "paper" in the content layer; glass is only for controls (Apple's guidance).
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            if model.readingManzil {
                                ManzilReader(model: model, theme: state.theme, palette: palette)
                                ManzilControls(model: model, palette: palette)
                            } else {
                                page
                                footer
                            }
                        }
                        .background(palette.page)
                        .overlay(alignment: .bottom) {
                            if let player {
                                BackToPlaying(model: model, player: player, palette: palette)
                                ContinueReciting(model: model, player: player, palette: palette)
                            }
                        }
                        overlay
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ReaderLayout.pageCornerRadius, style: .continuous))
                    .padding(.horizontal, ReaderLayout.pageInset)
                    if state.showTranslation {
                        TranslationStrip(model: model, playing: (player?.isActive ?? false) && model.followsPlayback, palette: palette)
                    }
                    if let player {
                        PlayerView(player: player, model: model, palette: palette)
                    }
                }
            }
        }
        .background(windowBackground)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.overlay)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: state.isShowingSettings)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: state.viewMode)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.readingManzil)
        // The first time a layout with page fonts is shown, fetch them once.
        .task(id: model.state.script) { model.preparePageFonts() }
    }

    private var palette: ReaderPalette { ReaderPalette(state: state) }

    /// The window shows through: the popover's (or detached window's) own glass or frosted material.
    /// Frosted on macOS 26 covers the popover's glass with a standard material; Sepia warms either.
    @ViewBuilder private var windowBackground: some View {
        ZStack {
            if state.glassStyle == .frosted && GlassStyle.isGlassAvailable { Rectangle().fill(.regularMaterial) }
            if state.theme == .sepia { palette.chrome.opacity(0.55) }
        }
    }

    /// The page. It slides in from the left when moving forward through the mushaf (right to left) and
    /// from the right when moving back (a fade with Reduce Motion); the page view animates that itself.
    private var page: some View {
        MushafPageView(model: model, content: .page(model.pageNumber), theme: state.theme, accent: palette.accentColor)
            .accessibilityLabel("Mushaf page \(model.pageNumber)")
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if DEBUG
    /// Snapshots only: open the surah picker on the juz list with these expanded.
    var debugExpandedJuz: Set<Int>?
    #else
    let debugExpandedJuz: Set<Int>? = nil
    #endif

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
                    HeaderTitle(model: model, palette: palette)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(palette.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.library == nil)
            .help("Go to a surah or juz")
            .accessibilityLabel("Go to a surah or juz")
            .popover(isPresented: popoverBinding(.surahPicker), arrowEdge: .bottom) {
                SurahPicker(model: model, palette: palette, downloads: downloads, reciter: player?.reciter).frame(width: 300, height: 380)
            }

            Spacer(minLength: 6)

            // Related actions share one capsule, as toolbar groups do in macOS 26.
            ControlCluster(style: palette.glass) {
                if let annotations = model.annotations {
                    headerButton("Bookmarks, highlights, and notes", symbol: model.overlay == .annotations ? "bookmark.fill" : "bookmark") {
                        toggle(.annotations)
                    }
                    .disabled(model.library == nil)
                    .popover(isPresented: popoverBinding(.annotations), arrowEdge: .bottom) {
                        AnnotationsPanel(model: model, annotations: annotations, palette: palette).frame(width: 320, height: 380)
                    }
                }
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
        }
        .padding(.leading, 14)
        .padding(.trailing, ReaderLayout.pageInset)
        .frame(height: ReaderLayout.headerHeight)
    }

    private func headerButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ClusterButtonStyle())
        .foregroundStyle(palette.ink.opacity(0.8))
        .help(label)
        .accessibilityLabel(label)
    }

    /// Opens or closes an overlay. Clicks closer together than the transition are ignored, so rapid
    /// clicking cannot stack half-finished transitions.
    private func toggle(_ overlay: ReaderModel.Overlay) {
        let now = CACurrentMediaTime()
        guard now - Self.lastToggle > 0.3 else { return }
        Self.lastToggle = now
        model.overlay = model.overlay == overlay ? nil : overlay
    }

    @MainActor private static var lastToggle = 0.0

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
            SurahPicker(model: model, palette: palette, downloads: downloads, reciter: player?.reciter, debugExpandedJuz: debugExpandedJuz)
                .overlayCard(palette)
                .transition(Motion.overlay(reduceMotion: reduceMotion))
        case .jump:
            JumpBox(model: model, palette: palette)
                .padding(8)
                .transition(Motion.overlay(reduceMotion: reduceMotion))
        case .annotations:
            if let annotations = model.annotations {
                AnnotationsPanel(model: model, annotations: annotations, palette: palette)
                    .overlayCard(palette)
                    .transition(Motion.overlay(reduceMotion: reduceMotion))
            }
        case .note(let ayah):
            if let annotations = model.annotations {
                NoteEditor(ayah: ayah, model: model, annotations: annotations, palette: palette)
                    .padding(8)
                    .transition(Motion.overlay(reduceMotion: reduceMotion))
            }
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
                if let annotations = model.annotations {
                    let ayah = model.state.selectedAyah
                    if annotations.isBookmarked(ayah) {
                        Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(palette.accent).help("Bookmarked")
                    }
                    if let highlight = annotations.highlights[ayah] {
                        Circle().fill(Color(nsColor: highlight.color.swatch)).frame(width: 8, height: 8).help("\(highlight.color.title) highlight")
                    }
                }
                Spacer()
                if let info = model.translation?.info {
                    // QuranEnc's terms: credit the publisher, the source, and the version.
                    Text(info.name).font(.caption).foregroundStyle(palette.secondary).lineLimit(1).help(info.credit)
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.selectedTranslation ?? "No translation is available.")
                            .font(.callout)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        // The translator's footnotes, as in a printed translation.
                        if let footnotes = model.translation?.footnotes(for: model.state.selectedAyah) {
                            Text(footnotes)
                                .font(.caption)
                                .foregroundStyle(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, model.translation?.info.isRightToLeft == true ? .rightToLeft : .leftToRight)
                    if let note = model.annotations?.notes[model.state.selectedAyah] {
                        Label(note.text, systemImage: "note.text")
                            .font(.callout.italic())
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .onTapGesture(count: 2) { model.overlay = .note(model.state.selectedAyah) }
                            .help("Your note. Double-click to edit")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ReaderLayout.translationTextHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: ReaderLayout.translationHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.translation?.info.name ?? "Translation") of ayah \(model.state.selectedAyah.description)")
        .accessibilityValue(accessibilityText)
    }

    /// The translation, its footnotes, and the note, read in that order.
    private var accessibilityText: String {
        let ayah = model.state.selectedAyah
        return [model.selectedTranslation, model.translation?.footnotes(for: ayah),
                model.annotations?.notes[ayah].map { "Your note: \($0.text)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

private extension View {
    /// A full-page overlay (surah picker, annotations) on a glass sheet inset within the page card.
    func overlayCard(_ palette: ReaderPalette) -> some View {
        self.surface(palette.glass, in: RoundedRectangle(cornerRadius: ReaderLayout.pageCornerRadius - 4, style: .continuous))
            .padding(6)
    }
}

// The selected ayah changes with every recited ayah. Only these small views read it, so the rest of the
// reader (its header, player, and their glass) is not re-evaluated each time.

/// The header's title: the current surah and juz, or the Manzil.
private struct HeaderTitle: View {
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if model.readingManzil {
                Text("Manzil").font(.headline).lineLimit(1)
                Text("18 passages").font(.caption).foregroundStyle(palette.secondary)
            } else {
                Text(model.currentSurah?.nameSimple ?? "Surabar").font(.headline).lineLimit(1)
                if let surah = model.currentSurah, let info = model.pageInfo {
                    Text("Surah \(surah.number) · Juz \(info.juz)").font(.caption).foregroundStyle(palette.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown over the page bottom while recitation plays elsewhere, as Maps offers to re-centre.
/// "Continue Al-Kahf 18:45": the recitation paused (or remembered from the last session) somewhere other than
/// the selected ayah. Clicking it shows that ayah and plays on from it; × hides it until another pause.
private struct ContinueReciting: View {
    let model: ReaderModel
    let player: RecitationPlayer
    let palette: ReaderPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ayah: AyahKey? {
        guard let ayah = player.resumableAyah, model.dismissedResume != ayah, !model.readingManzil else { return nil }
        return model.state.selectedAyah == ayah && model.isOnPage(ayah) ? nil : ayah
    }

    var body: some View {
        ZStack {
            if let ayah {
                HStack(spacing: 2) {
                    Button {
                        model.returnToPlayback(at: ayah)
                        player.resume()
                    } label: {
                        Label("Continue \(model.store?.surah(ayah.surah)?.nameSimple ?? "") \(ayah.description)", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.leading, 14)
                            .padding(.trailing, 6)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(ayah.description) and continue the recitation from there")
                    Button { model.dismissedResume = ayah } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide")
                    .accessibilityLabel("Hide Continue")
                }
                .foregroundStyle(palette.onAccent)
                .surface(palette.glass, in: Capsule(), interactive: true, tint: palette.accent)
                .padding(.bottom, ReaderLayout.footerHeight + 10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: ayah)
    }
}

private struct BackToPlaying: View {
    let model: ReaderModel
    let player: RecitationPlayer
    let palette: ReaderPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shows: Bool {
        guard player.isActive, let ayah = player.ayah else { return false }
        return !model.followsPlayback && !(model.isOnPage(ayah) && model.state.selectedAyah == ayah)
    }

    var body: some View {
        ZStack {
            if shows, let ayah = player.ayah {
                Button { model.returnToPlayback(at: ayah) } label: {
                    Label("Back to playing \(ayah.description)", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                        // Tinted glass suggests prominence (Apple's guidance for custom glass).
                        .surface(palette.glass, in: Capsule(), interactive: true, tint: palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.bottom, ReaderLayout.footerHeight + 10)
                .help("Show the ayah being recited and follow it again")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: shows)
    }
}

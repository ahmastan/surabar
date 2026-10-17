import MushafRendering
import Recitation
import SwiftUI

/// The Manzil in the main reading area: its 18 passages, one after another, each set in justified lines
/// like the mushaf page and drawn by the same page view, so selecting an ayah, its translation, highlights,
/// notes, and the ayah menu work as on a page. Scrolls to the selected (or recited) ayah's passage.
struct ManzilReader: View {
    let model: ReaderModel
    let theme: ReaderTheme
    let palette: ReaderPalette

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Manzil.passages.indices, id: \.self) { index in
                            passage(index, width: geometry.size.width).id(index)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: model.state.selectedAyah) { scroll(proxy, animated: true) }
            }
        }
    }

    /// Keeps the selected ayah's passage in view (recitation selects the recited ayah).
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let index = Manzil.passage(containing: model.state.selectedAyah) else { return }
        if animated {
            withAnimation(Motion.standard) { proxy.scrollTo(index, anchor: .top) }
        } else {
            proxy.scrollTo(index, anchor: .top)
        }
    }

    private func passage(_ index: Int, width: Double) -> some View {
        let range = Manzil.passages[index]
        let name = model.store?.surah(range.lowerBound.surah)?.nameSimple ?? "Surah \(range.lowerBound.surah)"
        let ayahs = range.lowerBound == range.upperBound ? "\(range.lowerBound.ayah)" : "\(range.lowerBound.ayah)–\(range.upperBound.ayah)"
        let height = model.manzilLayout(passage: index, width: width)?.size.height ?? 0
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(palette.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text("\(name) \(ayahs)").font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                Spacer()
                Button {
                    model.goTo(range.lowerBound)
                } label: {
                    Image(systemName: "book").font(.caption)
                }
                .buttonStyle(ClusterButtonStyle(width: 24, height: 20))
                .foregroundStyle(palette.secondary)
                .help("Show in mushaf")
                .accessibilityLabel("Show \(name) \(ayahs) in the mushaf")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            MushafPageView(model: model, content: .manzil(index), theme: theme, accent: palette.accentColor)
                .frame(height: height)
        }
    }
}

/// Below the Manzil, in the page footer's place: the way back to the mushaf, and "Read today" with the
/// days in a row. Playing and repeating use the player and its Loop button.
struct ManzilControls: View {
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        let state = model.state
        let today = Date()
        let read = state.manzilRoutine.isRead(on: today)
        let streak = state.manzilRoutine.streak(on: today)
        HStack(spacing: 8) {
            Button(action: model.closeManzil) {
                Label("Mushaf", systemImage: "chevron.left").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .help("Back to the mushaf")
            Spacer(minLength: 4)
            Button {
                withAnimation(Motion.quick) { state.manzilRoutine.setRead(!read, on: today) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: read ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(read ? palette.accent : palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text("Read today")
                    if streak > 1 { Text("· \(streak) days").foregroundStyle(palette.secondary).monospacedDigit() }
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(read ? "Marked as read today" : "Mark the Manzil as read today")
            .accessibilityLabel("Read today")
            .accessibilityValue(read ? "Yes" + (streak > 1 ? ", \(streak) days in a row" : "") : "No")
        }
        .padding(.horizontal, 10)
        .frame(height: ReaderLayout.footerHeight)
    }
}

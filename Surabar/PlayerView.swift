import MushafRendering
import Recitation
import SwiftUI

/// Recitation controls: a progress line through the current ayah, the transport (skip by surah or page,
/// previous and next ayah, play/pause), and the labelled Reciter, Speed, and Loop controls.
struct PlayerView: View {
    let player: RecitationPlayer
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        VStack(spacing: 4) {
            progress.frame(height: 14)
            transport.frame(height: 40)
            HStack(spacing: 6) {
                OptionMenu(label: "Reciter", value: player.reciter.displayName, palette: palette, sections: [
                    OptionSection(title: "Reciter", items: player.reciters.map { reciter in
                        OptionItem(id: "\(reciter.id)", title: reciter.displayName, isSelected: reciter.id == player.reciter.id) {
                            player.setReciter(reciter.id)
                        }
                    }),
                ])
                OptionMenu(label: "Speed", value: speedName(model.state.speed), palette: palette, sections: [
                    OptionSection(title: "Playback speed", items: [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { speed in
                        OptionItem(id: "\(speed)", title: speedName(speed, long: true), isSelected: speed == model.state.speed) {
                            player.setSpeed(speed)
                        }
                    }),
                ])
                .frame(width: 74)
                LoopControl(player: player, state: model.state, palette: palette)
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(height: ReaderLayout.playerHeight)
    }

    // MARK: Parts

    /// The ayah's progress line, or the reason playback stopped with a way to retry.
    @ViewBuilder private var progress: some View {
        if case .failed(let message) = player.status {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(palette.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Retry", action: player.retry).buttonStyle(.link)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        } else {
            ProgressBar(fraction: player.duration > 0 ? player.elapsed / player.duration : 0, palette: palette,
                        seek: player.seek(toFraction:))
        }
    }

    /// Where the transport starts from: the recited (or paused) ayah, otherwise the selection.
    private var position: AyahKey { player.ayah ?? model.state.selectedAyah }

    private var transport: some View {
        let unit = model.state.skipUnit
        let back = model.skipTarget(from: position, direction: -1, unit: unit)
        let forward = model.skipTarget(from: position, direction: 1, unit: unit)
        return HStack(spacing: 10) {
            transportButton(skipBackLabel(target: back), symbol: "backward.end.fill", size: 13, disabled: back == nil) {
                if let back { player.skip(to: back) }
            }
            transportButton("Previous ayah (⌥→)", symbol: "backward.fill", size: 15) {
                player.stepAyah(-1, from: model.state.selectedAyah)
            }
            Button {
                player.togglePlayPause(startingAt: model.state.selectedAyah)
            } label: {
                Image(systemName: player.isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(palette.accent))
                    .opacity(player.status == .loading ? 0.75 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play or pause (Space)")
            .accessibilityLabel(player.isActive ? "Pause" : "Play")
            transportButton("Next ayah (⌥←)", symbol: "forward.fill", size: 15) {
                player.stepAyah(1, from: model.state.selectedAyah)
            }
            transportButton("Next \(unit.title.lowercased()) (⌘←)", symbol: "forward.end.fill", size: 13, disabled: forward == nil) {
                if let forward { player.skip(to: forward) }
            }
        }
    }

    /// Back goes to the start of the current surah or page first, as a media player's Previous does.
    private func skipBackLabel(target: AyahKey?) -> String {
        let unit = model.state.skipUnit
        let restarts = switch unit {
        case .surah: target?.surah == position.surah
        case .page: target != nil && target == model.pageRange(of: position)?.lowerBound
        }
        return (restarts ? "Start of \(unit.title.lowercased())" : "Previous \(unit.title.lowercased())") + " (⌘→)"
    }

    private func transportButton(_ label: String, symbol: String, size: CGFloat, disabled: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(label)
    }

    private func speedName(_ speed: Double, long: Bool = false) -> String {
        if speed == 1 { return long ? "Normal (1×)" : "1×" }
        return "\(speed.formatted(.number.precision(.fractionLength(0 ... 2))))×"
    }
}

/// The Loop split button: clicking the icon and name cycles Off → Ayah → Surah/Page; the chevron
/// (or a right-click) opens the menu with the mode, repeat count, and pause between repeats.
struct LoopControl: View {
    let player: RecitationPlayer
    let state: AppState
    let palette: ReaderPalette
    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: player.cycleLoop) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LOOP").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(palette.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: state.loopMode == .ayah ? "repeat.1" : state.loopMode == .range ? "arrow.left.and.right" : "repeat")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.loopMode == .off ? palette.secondary : palette.accent)
                        Text(value).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Loop: \(value). Click to change (R)")
            .accessibilityLabel("Loop: \(value)")
            .accessibilityHint("Cycles off, repeat ayah, and repeat \(state.skipUnit.title.lowercased())")
            Rectangle().fill(palette.secondary.opacity(0.35)).frame(width: 0.5).padding(.vertical, 6)
            Button { isOpen.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.secondary)
                    .frame(width: 22).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Loop options")
            .accessibilityLabel("Loop options")
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                OptionList(sections: sections, accent: palette.accent, onAccent: palette.onAccent) { isOpen = false }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.secondary.opacity(0.35)))
        .contextMenu {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Button(action: item.action) {
                            if item.isSelected { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                        }
                    }
                }
            }
        }
    }

    private var value: String {
        if let start = state.loopRangeStart { return "From \(start)…" }
        let title = state.loopMode == .range ? state.loopRange?.title ?? "Range" : state.loopMode.title(unit: state.skipUnit)
        guard state.loopMode != .off else { return title }
        return state.repeatCount == 0 ? "\(title) ∞" : "\(title) ×\(state.repeatCount)"
    }

    private var sections: [OptionSection] {
        [
            OptionSection(title: "Repeat", items: LoopMode.allCases.filter { $0 != .range || state.loopRange != nil }.map { mode in
                let title = switch mode {
                case .off: "Off"
                case .ayah: "Each ayah"
                case .unit: "The whole \(state.skipUnit.title.lowercased())"
                case .range: "Ayahs \(state.loopRange?.title ?? "")"
                }
                return OptionItem(id: mode.rawValue, title: title, isSelected: state.loopMode == mode) { player.setLoop(mode) }
            }),
            OptionSection(title: "Times", items: AppState.repeatCounts.map { count in
                OptionItem(id: "count\(count)", title: count == 0 ? "Until stopped" : "\(count) times",
                           isSelected: state.repeatCount == count) { state.repeatCount = count }
            }),
            OptionSection(title: "Pause between repeats", items: (0 ... 5).map { seconds in
                OptionItem(id: "pause\(seconds)", title: seconds == 0 ? "None" : "\(seconds) s",
                           isSelected: state.repeatPause == Double(seconds)) { state.repeatPause = Double(seconds) }
            }),
        ]
    }
}

/// "Player only": the recited (or next) ayah's surah and number, and its Arabic text on one line,
/// scrolling when it is longer than the window.
struct NowPlayingCard: View {
    let player: RecitationPlayer
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        let ayah = player.ayah ?? model.state.selectedAyah
        let basmalah = player.step?.kind == .basmalah
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.store?.surah(ayah.surah)?.nameSimple ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail(ayah, basmalah: basmalah)).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            ArabicMarquee(text: arabic(ayah, basmalah: basmalah), font: arabicFont)
                .frame(height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(height: ReaderLayout.nowPlayingHeight)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ ayah: AyahKey, basmalah: Bool) -> String {
        var text = basmalah ? "Basmalah" : "Ayah \(ayah.ayah)"
        if let step = player.step, step.kind == .ayah, model.state.loopMode == .ayah, model.state.repeatCount != 1 {
            text += model.state.repeatCount == 0 ? " · repeat \(step.repetition)" : " · \(step.repetition) of \(model.state.repeatCount)"
        }
        return text
    }

    /// The source text for the layout being read; the basmalah is Al-Fatihah's first ayah.
    private func arabic(_ ayah: AyahKey, basmalah: Bool) -> String {
        guard let store = model.store, let layout = model.layout else { return "" }
        return (try? store.text(of: basmalah ? AyahKey(surah: 1, ayah: 1) : ayah, in: layout)) ?? ""
    }

    private var arabicFont: Font {
        model.font.map { Font($0.sized(21)) } ?? .title3
    }
}

/// One line of text that scrolls from its start (the right, for Arabic) to its end and back when it is
/// too long to fit. With Reduce Motion it stays still.
struct ArabicMarquee: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overflow = max(textWidth - boxWidth, 0)
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { Color.clear.preference(key: MarqueeWidth.self, value: $0.size.width) })
                .offset(x: offset)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                .onAppear { boxWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { boxWidth = geometry.size.width }
        }
        .clipped()
        .onPreferenceChange(MarqueeWidth.self) { width in MainActor.assumeIsolated { textWidth = width } }
        .task(id: "\(text)|\(Int(overflow))|\(reduceMotion)") {
            offset = 0
            guard overflow > 1, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Double(overflow) / 28).delay(0.5).repeatForever(autoreverses: true)) { offset = overflow }
        }
        .accessibilityLabel(text)
    }
}

private struct MarqueeWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct OptionItem: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
}

struct OptionSection: Identifiable {
    let title: String
    let items: [OptionItem]

    var id: String { title }
}

/// A clearly labelled control: a small caption above the current value, opening a list of choices.
/// (A SwiftUI Menu would flatten the two-line label on macOS.)
struct OptionMenu: View {
    let label: String
    let value: String
    let palette: ReaderPalette
    let sections: [OptionSection]
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(palette.secondary)
                    Text(value).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.secondary.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("\(label): \(value)")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            OptionList(sections: sections, accent: palette.accent, onAccent: palette.onAccent) { isOpen = false }
        }
    }
}

/// The choices shown by an OptionMenu, grouped under section titles, with the current ones checked.
struct OptionList: View {
    let sections: [OptionSection]
    let accent: Color
    let onAccent: Color
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    Text(section.title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
                    ForEach(section.items) { item in
                        Button {
                            item.action()
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.caption.weight(.semibold)).opacity(item.isSelected ? 1 : 0)
                                Text(item.title)
                                Spacer(minLength: 12)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(OptionRowStyle(accent: accent, onAccent: onAccent))
                        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(6)
        }
        .frame(minWidth: 220, maxHeight: 380)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct OptionRowStyle: ButtonStyle {
    let accent: Color
    let onAccent: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? onAccent : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? accent : .clear))
            .onHover { hovering = $0 }
    }
}

/// A thin progress track; clicking or dragging seeks.
struct ProgressBar: View {
    let fraction: Double
    let palette: ReaderPalette
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondary.opacity(0.25)).frame(height: 3)
                Capsule().fill(palette.accent).frame(width: geometry.size.width * min(max(fraction, 0), 1), height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { seek($0.location.x / max(geometry.size.width, 1)) })
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

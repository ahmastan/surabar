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
            // The transport centred, the volume at the right end, as in Music's player.
            ZStack(alignment: .trailing) {
                transport.frame(maxWidth: .infinity)
                VolumeControl(player: player, state: model.state, palette: palette).frame(height: 30)
            }
            .frame(height: 40)
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
            ProgressBar(player: player, speed: model.state.speed, palette: palette)
        }
    }

    /// The transport does not depend on the ayah being recited: its targets are worked out when a button
    /// is pressed. Otherwise every new ayah would rebuild its glass, briefly costing tens of megabytes
    /// of graphics memory.
    private var transport: some View {
        let unitName = player.inManzil ? "passage" : model.state.skipUnit.title.lowercased()
        // Two clusters either side of a prominent play button, as in Music's player on macOS 26.
        return HStack(spacing: 10) {
            ControlCluster(style: palette.glass) {
                transportButton("Start of this \(unitName), or the previous one (⌘→)", symbol: "backward.end.fill", size: 12) {
                    skip(-1)
                }
                transportButton("Previous ayah (⌥→)", symbol: "backward.fill", size: 14) {
                    player.stepAyah(-1, from: model.state.selectedAyah)
                }
            }
            Button {
                player.togglePlayPause(startingAt: model.state.selectedAyah)
            } label: {
                Image(systemName: player.isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .opacity(player.status == .loading ? 0.7 : 1)
                    .contentShape(Circle())
                    // Tinted, interactive glass marks the main action.
                    .surface(palette.glass, in: Circle(), interactive: true, tint: palette.accent)
            }
            .buttonStyle(.plain)
            .help("Play or pause (Space)")
            .accessibilityLabel(player.isActive ? "Pause" : "Play")
            ControlCluster(style: palette.glass) {
                transportButton("Next ayah (⌥←)", symbol: "forward.fill", size: 14) {
                    player.stepAyah(1, from: model.state.selectedAyah)
                }
                transportButton("Next \(unitName) (⌘←)", symbol: "forward.end.fill", size: 12) {
                    skip(1)
                }
            }
        }
    }

    /// Back goes to the start of the current surah, page, or passage first, as a media player's Previous does.
    private func skip(_ direction: Int) {
        let position = player.ayah ?? model.state.selectedAyah
        if let target = model.skipTarget(from: position, direction: direction, unit: model.state.skipUnit) {
            player.skip(to: target)
        }
    }

    private func transportButton(_ label: String, symbol: String, size: CGFloat, disabled: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
        }
        .buttonStyle(ClusterButtonStyle(width: 34, height: 30))
        .disabled(disabled)
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
                        Image(systemName: symbol)
                            .contentTransition(.symbolEffect(.replace))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isOn ? palette.accent : palette.secondary)
                        Text(value).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(player.inManzil ? "Recite the Manzil \(state.manzilRepeats == 0 ? "until stopped" : state.manzilRepeats == 1 ? "once" : "\(state.manzilRepeats) times"). Click to change (R)"
                  : "Loop: \(value). Click to change (R)")
            .accessibilityLabel("Loop: \(value)")
            .accessibilityHint(player.inManzil ? "Cycles how many times the Manzil is recited"
                               : "Cycles off, repeat ayah, and repeat \(state.skipUnit.title.lowercased())")
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
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

    private var symbol: String {
        if player.inManzil { return "repeat" }
        return switch state.loopMode {
        case .ayah: "repeat.1"
        case .range: "arrow.left.and.right"
        default: "repeat"
        }
    }

    /// Lit when something repeats: a loop, or the Manzil more than once.
    private var isOn: Bool {
        player.inManzil ? state.manzilRepeats != 1 : state.loopMode != .off
    }

    private var pauseSection: OptionSection {
        OptionSection(title: "Pause between repeats", items: (0 ... 5).map { seconds in
            OptionItem(id: "pause\(seconds)", title: seconds == 0 ? "None" : "\(seconds) s",
                       isSelected: state.repeatPause == Double(seconds)) { state.repeatPause = Double(seconds) }
        })
    }

    private var value: String {
        if player.inManzil {
            return state.manzilRepeats == 0 ? "Manzil ∞" : "Manzil ×\(state.manzilRepeats)"
        }
        if let start = state.loopRangeStart { return "From \(start)…" }
        let title = state.loopMode == .range ? state.loopRange?.title ?? "Range" : state.loopMode.title(unit: state.skipUnit)
        guard state.loopMode != .off else { return title }
        let count = state.loopMode == .manzil ? state.manzilRepeats : state.repeatCount
        return count == 0 ? "\(title) ∞" : "\(title) ×\(count)"
    }

    private var sections: [OptionSection] {
        // In the Manzil, the Loop only sets how many times the whole Manzil is recited.
        if player.inManzil {
            return [
                OptionSection(title: "Recite the Manzil", items: AppState.manzilRepeatCounts.map { count in
                    OptionItem(id: "manzil\(count)", title: count == 0 ? "Until stopped" : count == 1 ? "Once" : "\(count) times",
                               isSelected: state.manzilRepeats == count) { state.manzilRepeats = count }
                }),
                pauseSection,
            ]
        }
        return [
            // The Manzil is started from its booklet; it is listed only while it plays.
            OptionSection(title: "Repeat", items: LoopMode.allCases.filter {
                ($0 != .range || state.loopRange != nil) && ($0 != .manzil || state.loopMode == .manzil)
            }.map { mode in
                let title = switch mode {
                case .off: "Off"
                case .ayah: "Each ayah"
                case .unit: "The whole \(state.skipUnit.title.lowercased())"
                case .range: "Ayahs \(state.loopRange?.title ?? "")"
                case .manzil: "The Manzil"
                }
                return OptionItem(id: mode.rawValue, title: title, isSelected: state.loopMode == mode) { player.setLoop(mode) }
            }),
            OptionSection(title: "Times", items: AppState.repeatCounts.map { count in
                OptionItem(id: "count\(count)", title: count == 0 ? "Until stopped" : "\(count) times",
                           isSelected: state.repeatCount == count) { state.repeatCount = count }
            }),
            pauseSection,
        ]
    }
}

/// The recitation's loudness: a speaker showing the level, which opens a slider.
struct VolumeControl: View {
    let player: RecitationPlayer
    let state: AppState
    let palette: ReaderPalette
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ClusterButtonStyle(width: 32, height: 30))
        .help("Volume: \(Int((state.volume * 100).rounded())) %")
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((state.volume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.setVolume(state.volume + 0.1)
            case .decrement: player.setVolume(state.volume - 0.1)
            @unknown default: break
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            HStack(spacing: 10) {
                Button { player.setVolume(state.volume > 0 ? 0 : 1) } label: {
                    Image(systemName: state.volume > 0 ? "speaker.fill" : "speaker.slash.fill").frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(state.volume > 0 ? "Mute" : "Unmute")
                Slider(value: Binding(get: { state.volume }, set: { player.setVolume($0) }), in: 0 ... 1)
                    .frame(width: 160)
                    .accessibilityLabel("Volume")
                Text("\(Int((state.volume * 100).rounded())) %").font(.caption).monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            .padding(12)
            .tint(palette.accent)
        }
    }

    private var symbol: String {
        switch state.volume {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// "Player only": the recited (or next) ayah's surah and number.
struct NowPlayingCard: View {
    let player: RecitationPlayer
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        let ayah = player.ayah ?? model.state.selectedAyah
        let basmalah = player.step?.kind == .basmalah
        HStack(alignment: .firstTextBaseline) {
            Text(model.store?.surah(ayah.surah)?.nameSimple ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(detail(ayah, basmalah: basmalah)).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
            Spacer(minLength: 0)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
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

/// A thin progress line through the current ayah; clicking or dragging seeks. While playing, the line is
/// a Core Animation fill that runs to the end of the ayah by itself, so the app does no work per frame;
/// it is re-aimed only when the position is measured (once a second) or playback changes.
struct ProgressBar: View {
    let player: RecitationPlayer
    let speed: Double
    let palette: ReaderPalette

    var body: some View {
        let fraction = player.progressFraction
        ProgressLine(fraction: fraction,
                     secondsLeft: player.status == .playing && player.duration > 0 ? (1 - fraction) * player.duration / max(speed, 0.1) : nil,
                     fill: palette.accentColor, track: NSColor(palette.secondary).withAlphaComponent(0.25),
                     seek: player.seek(toFraction:))
            .frame(height: 12)
            .accessibilityElement()
            .accessibilityLabel("Position in the ayah")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            // VoiceOver: step through the ayah a tenth at a time.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(toFraction: min(fraction + 0.1, 0.99))
                case .decrement: player.seek(toFraction: max(fraction - 0.1, 0))
                @unknown default: break
                }
            }
    }
}

private struct ProgressLine: NSViewRepresentable {
    let fraction: Double
    /// Seconds until the ayah ends while playing; nil while paused or stopped.
    let secondsLeft: Double?
    let fill: NSColor
    let track: NSColor
    let seek: (Double) -> Void

    func makeNSView(context: Context) -> ProgressLineView { ProgressLineView() }

    func updateNSView(_ view: ProgressLineView, context: Context) {
        view.seek = seek
        view.update(fraction: fraction, secondsLeft: secondsLeft, fill: fill, track: track)
    }
}

final class ProgressLineView: NSView {
    var seek: ((Double) -> Void)?
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var fraction = 0.0
    private var secondsLeft: Double?
    private var colors: (fill: NSColor, track: NSColor) = (.controlAccentColor, .tertiaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(fraction: Double, secondsLeft: Double?, fill: NSColor, track: NSColor) {
        self.fraction = fraction
        self.secondsLeft = secondsLeft
        colors = (fill, track)
        layoutLine()
    }

    override func layout() {
        super.layout()
        layoutLine()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutLine()
    }

    private func layoutLine() {
        let height = 3.0
        let line = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = colors.track.cgColor
            fillLayer.backgroundColor = colors.fill.cgColor
        }
        trackLayer.frame = line
        trackLayer.cornerRadius = height / 2
        fillLayer.cornerRadius = height / 2
        fillLayer.bounds = CGRect(x: 0, y: 0, width: line.width * fraction, height: height)
        fillLayer.position = CGPoint(x: line.minX, y: line.midY)
        fillLayer.removeAnimation(forKey: "progress")
        if let secondsLeft, secondsLeft > 0, line.width > 0 {
            // Runs in the render server: the fill grows to the end of the ayah as it plays.
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = line.width * fraction
            grow.toValue = line.width
            grow.duration = secondsLeft
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            // A slow line needs few frames; at the display's full rate, every frame would also make the
            // window server recompute the glass around it.
            grow.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
            fillLayer.add(grow, forKey: "progress")
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { seekTo(event) }
    override func mouseDragged(with event: NSEvent) { seekTo(event) }

    private func seekTo(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        seek?(min(max(convert(event.locationInWindow, from: nil).x / bounds.width, 0), 1))
    }
}

import MushafRendering
import Recitation
import SwiftUI

/// Recitation controls: progress, transport, and labelled Reciter and Speed menus.
struct PlayerView: View {
    let player: RecitationPlayer
    let model: ReaderModel
    let palette: ReaderPalette

    var body: some View {
        VStack(spacing: 6) {
            ProgressBar(fraction: player.duration > 0 ? player.elapsed / player.duration : 0, palette: palette,
                        seek: player.seek(toFraction:))
            HStack(spacing: 6) {
                status.frame(maxWidth: .infinity, alignment: .leading)
                transport
                Text(timeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
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
                .frame(width: 92)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: ReaderLayout.playerHeight)
    }

    // MARK: Parts

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch player.status {
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                Button("Retry", action: player.retry).buttonStyle(.link).font(.caption)
            default:
                Text(statusTitle).font(.caption.weight(.semibold)).lineLimit(1)
                Text("to surah end").font(.caption2).foregroundStyle(palette.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch player.status {
        case .idle: "Ready"
        case .loading where player.step?.kind == .basmalah, .playing where player.step?.kind == .basmalah: "Basmalah"
        case .loading, .playing: player.ayah.map { "Ayah \($0)" } ?? "Playing"
        case .paused: player.ayah.map { "Paused · \($0)" } ?? "Paused"
        case .failed: ""
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            transportButton("Previous ayah", symbol: "backward.end.fill") {
                player.stepAyah(-1, from: model.state.selectedAyah)
            }
            Button {
                player.togglePlayPause(startingAt: model.state.selectedAyah)
            } label: {
                Image(systemName: player.isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.accent))
                    .opacity(player.status == .loading ? 0.75 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play or pause (Space)")
            .accessibilityLabel(player.isActive ? "Pause" : "Play")
            transportButton("Next ayah", symbol: "forward.end.fill") {
                player.stepAyah(1, from: model.state.selectedAyah)
            }
        }
    }

    private func transportButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var timeText: String {
        guard player.duration > 0 else { return "" }
        return "\(clock(player.elapsed)) / \(clock(player.duration))"
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private func speedName(_ speed: Double, long: Bool = false) -> String {
        if speed == 1 { return long ? "Normal (1×)" : "1×" }
        return "\(speed.formatted(.number.precision(.fractionLength(0 ... 2))))×"
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

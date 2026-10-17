import QuranStore
import Recitation
import SwiftUI

/// A download control: an arrow to download, a progress ring that cancels, and a checkmark whose menu deletes.
struct DownloadButton: View {
    let status: DownloadCenter.Status
    let title: String
    let palette: ReaderPalette
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        switch status {
        case .none, .partial:
            Button(action: download) {
                Image(systemName: "arrow.down.circle").font(.system(size: 15)).foregroundStyle(palette.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel("Download \(title)")
        case .downloading(let fraction):
            Button(action: cancel) {
                ZStack {
                    Circle().stroke(palette.secondary.opacity(0.3), lineWidth: 2)
                    Circle().trim(from: 0, to: max(fraction, 0.03)).stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RoundedRectangle(cornerRadius: 1.5).fill(palette.accent).frame(width: 6, height: 6)
                }
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Downloading \(Int(fraction * 100))%. Click to stop")
            .accessibilityLabel("Stop downloading \(title)")
            .accessibilityValue("\(Int(fraction * 100)) percent")
        case .downloaded:
            Menu {
                Button("Delete Download", role: .destructive, action: delete)
            } label: {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(palette.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .help("Downloaded for offline listening")
            .accessibilityLabel("\(title) downloaded")
        }
    }

    private var helpText: String {
        if case .partial(let fraction) = status, fraction > 0 {
            return "Download for offline listening (\(Int(fraction * 100))% already saved)"
        }
        return "Download for offline listening"
    }
}

/// Settings › Player › Manage downloads: every surah and juz for the current reciter.
struct DownloadsView: View {
    let downloads: DownloadCenter
    let model: ReaderModel
    let reciter: Reciter
    let palette: ReaderPalette
    @State private var showsJuz = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.state.showsDownloads = false } label: {
                    Label("Player", systemImage: "chevron.left").font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                Spacer()
                Picker("Show", selection: $showsJuz) {
                    Text("Surahs").tag(false)
                    Text("Juz").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("Downloads for \(reciter.displayName). Downloaded recitations play offline and are never removed to save space.")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsGroup(palette: palette) {
                if showsJuz {
                    ForEach(1 ... 30, id: \.self) { juz in
                        let surahs = model.surahs(inJuz: juz)
                        row(title: "Juz \(juz)", detail: surahRange(surahs), number: juz,
                            status: downloads.status(surahs: surahs, reciter: reciter), surahs: surahs)
                        if juz < 30 { Divider() }
                    }
                } else {
                    ForEach(model.store?.surahs ?? [], id: \.number) { surah in
                        row(title: surah.nameSimple, detail: size(surah.number), number: surah.number,
                            status: downloads.status(surah: surah.number, reciter: reciter), surahs: [surah.number])
                        if surah.number < 114 { Divider() }
                    }
                }
            }
        }
    }

    private func row(title: String, detail: String, number: Int, status: DownloadCenter.Status, surahs: [Int]) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").monospacedDigit().foregroundStyle(palette.secondary).frame(width: 24, alignment: .trailing)
            Text(title)
            Spacer(minLength: 8)
            Text(detail).font(.caption).foregroundStyle(palette.secondary).monospacedDigit()
            DownloadButton(status: status, title: title, palette: palette,
                           download: { downloads.download(surahs: surahs, reciter: reciter) },
                           cancel: { downloads.cancel(surahs: surahs, reciter: reciter) },
                           delete: { downloads.delete(surahs: surahs, reciter: reciter) })
        }
        .padding(.vertical, 5)
    }

    private func surahRange(_ surahs: [Int]) -> String {
        guard let first = surahs.first, let last = surahs.last else { return "" }
        return first == last ? "Surah \(first)" : "Surahs \(first)–\(last)"
    }

    /// The recording's size once known (after part of it has been fetched).
    private func size(_ surah: Int) -> String {
        guard let file = downloads.files[downloads.key(surah: surah, reciter: reciter)] else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file)
    }
}

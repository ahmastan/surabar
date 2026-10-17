import MushafRendering
import QuranStore
import Recitation
import SwiftUI

/// Searchable list of surahs and juz, shown over the page.
struct SurahPicker: View {
    let model: ReaderModel
    let palette: ReaderPalette
    /// Offers a download beside each surah and juz, for the current reciter.
    var downloads: DownloadCenter?
    var reciter: Reciter?
    @State private var mode = Mode.surahs
    @State private var query = ""
    /// Juz whose surahs are listed.
    @State private var expanded: Set<Int> = []
    #if DEBUG
    /// For snapshots: open on the juz list with these juz expanded.
    var debugExpandedJuz: Set<Int>?
    #endif
    @FocusState private var searchFocused: Bool

    enum Mode: String, CaseIterable {
        case surahs = "Surahs", juz = "Juz"
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(mode == .surahs ? "Search surahs" : "Juz number", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(openFirst)
            // Each list has its own scroll view and row IDs ("surah-2", "juz-2"), so switching tabs never
            // reuses the other list's rows.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if mode == .surahs {
                            ForEach(surahs) { surah in
                                row(number: surah.number, title: surah.nameSimple,
                                    detail: "\(surah.ayahCount) ayahs · \(surah.revelationPlace.capitalized)",
                                    trailing: surah.nameArabic, current: surah.number == model.currentSurah?.number, surahs: [surah.number]) {
                                    open(AyahKey(surah: surah.number, ayah: 1))
                                }
                                .id("surah-\(surah.number)")
                            }
                        } else {
                            ForEach(juzList, id: \.self) { juz in
                                juzRow(juz).id("juz-\(juz)")
                            }
                        }
                    }
                }
                .id(mode)
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: mode) { scrollToCurrent(proxy) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.chrome)
        .onAppear {
            searchFocused = true
            #if DEBUG
            if let debugExpandedJuz {
                mode = .juz
                expanded = debugExpandedJuz
            }
            #endif
        }
        .onChange(of: mode) { query = "" }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        let target = mode == .surahs ? "surah-\(model.currentSurah?.number ?? 1)" : "juz-\(model.pageInfo?.juz ?? 1)"
        // After the new list has laid out.
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
    }

    private func open(_ ayah: AyahKey) {
        model.overlay = nil
        model.goTo(ayah)
    }

    /// A juz, with a disclosure arrow that lists its surahs and the ayahs of each in this juz.
    @ViewBuilder private func juzRow(_ juz: Int) -> some View {
        let contents = model.juzContents(juz)
        let isExpanded = expanded.contains(juz)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expanded.remove(juz) } else { expanded.insert(juz) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide surahs" : "Show surahs")
                .accessibilityLabel(isExpanded ? "Hide the surahs in juz \(juz)" : "Show the surahs in juz \(juz)")
                row(number: juz, title: "Juz \(juz)", detail: juzDetail(contents), trailing: "",
                    current: juz == model.pageInfo?.juz, surahs: contents.map(\.surah.number)) {
                    model.overlay = nil
                    model.goTo(juz: juz)
                }
            }
            if isExpanded {
                ForEach(contents, id: \.surah.number) { part in
                    row(number: part.surah.number, title: part.surah.nameSimple, detail: ayahRange(part.ayahs, of: part.surah),
                        trailing: part.surah.nameArabic, current: false, surahs: [part.surah.number]) {
                        open(AyahKey(surah: part.surah.number, ayah: part.ayahs.lowerBound))
                    }
                    .padding(.leading, 26)
                }
                .transition(.opacity)
            }
        }
    }

    /// Where a juz begins, e.g. "Al-Baqarah 142 – Al-Baqarah 252".
    private func juzDetail(_ contents: [(surah: Surah, ayahs: ClosedRange<Int>)]) -> String {
        guard let first = contents.first, let last = contents.last else { return "" }
        return "\(first.surah.nameSimple) \(first.ayahs.lowerBound) – \(last.surah.nameSimple) \(last.ayahs.upperBound)"
    }

    private func ayahRange(_ ayahs: ClosedRange<Int>, of surah: Surah) -> String {
        ayahs.count == surah.ayahCount ? "All \(surah.ayahCount) ayahs" : "Ayahs \(ayahs.lowerBound)–\(ayahs.upperBound)"
    }

    private var surahs: [Surah] {
        let all = model.store?.surahs ?? []
        let needle = JumpQuery.normalized(query)
        guard !needle.isEmpty else { return all }
        return all.filter { "\($0.number)" == needle || JumpQuery.normalized($0.nameSimple).contains(needle) || $0.nameArabic.contains(query) }
    }

    private var juzList: [Int] {
        let all = Array(1 ... 30)
        guard let number = Int(query.trimmingCharacters(in: .whitespaces)) else { return all }
        return all.filter { "\($0)".hasPrefix("\(number)") }
    }

    private func openFirst() {
        if mode == .surahs, let surah = surahs.first {
            open(AyahKey(surah: surah.number, ayah: 1))
        } else if mode == .juz, let juz = juzList.first {
            model.overlay = nil
            model.goTo(juz: juz)
        }
    }

    private func row(number: Int, title: String, detail: String, trailing: String, current: Bool, surahs: [Int],
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            rowButton(number: number, title: title, detail: detail, trailing: trailing, current: current, action: action)
            if let downloads, let reciter {
                DownloadButton(status: surahs.count == 1 ? downloads.status(surah: surahs[0], reciter: reciter)
                                                         : downloads.status(surahs: surahs, reciter: reciter),
                               title: title, palette: palette,
                               download: { downloads.download(surahs: surahs, reciter: reciter) },
                               cancel: { downloads.cancel(surahs: surahs, reciter: reciter) },
                               delete: { downloads.delete(surahs: surahs, reciter: reciter) })
            }
        }
    }

    private func rowButton(number: Int, title: String, detail: String, trailing: String, current: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)").monospacedDigit().foregroundStyle(palette.secondary).frame(width: 26, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(current ? .semibold : .regular)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(palette.secondary) }
                }
                Spacer()
                Text(trailing).foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(current ? palette.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(detail.isEmpty ? "" : ", \(detail)")")
    }
}

/// Jump box: an ayah such as 2:255, an ayah number in the current surah, "p 50", or a surah name.
struct JumpBox: View {
    let model: ReaderModel
    let palette: ReaderPalette
    /// Drawn as a floating card over the page; a popover supplies its own frame.
    var framed = true
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("2:255, 5, p 50, or a surah name", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = suggestions.first { model.jump(to: first.target) } }
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { model.jump(to: suggestion.target) } label: {
                            HStack {
                                Text(suggestion.title).fontWeight(index == 0 ? .semibold : .regular)
                                Spacer()
                                Text(suggestion.detail).font(.caption).foregroundStyle(palette.secondary)
                                if index == 0 { Image(systemName: "return").font(.caption).foregroundStyle(palette.secondary) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(index == 0 ? palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No match").font(.caption).foregroundStyle(palette.secondary).padding(.horizontal, 8)
            }
        }
        .padding(10)
        .background(palette.chrome, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(framed ? 0.18 : 0), radius: 12, y: 4)
        .onAppear { focused = true }
    }

    private var suggestions: [JumpSuggestion] {
        guard let store = model.store, let layout = model.layout else { return [] }
        return JumpQuery.suggestions(for: query, currentSurah: model.currentSurah?.number ?? 1, surahs: store.surahs,
                                     pageCount: layout.pageCount)
    }
}

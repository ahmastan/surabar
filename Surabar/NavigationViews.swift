import MushafRendering
import QuranStore
import SwiftUI

/// Searchable list of surahs and juz, shown over the page.
struct SurahPicker: View {
    let model: ReaderModel
    let palette: ReaderPalette
    @State private var mode = Mode.surahs
    @State private var query = ""
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                    if mode == .surahs {
                        ForEach(surahs) { surah in
                            row(number: surah.number, title: surah.nameSimple, detail: "\(surah.ayahCount) ayahs · \(surah.revelationPlace.capitalized)",
                                trailing: surah.nameArabic, current: surah.number == model.currentSurah?.number) {
                                model.overlay = nil
                                model.goTo(surah: surah.number)
                            }
                            .id(surah.number)
                        }
                    } else {
                        ForEach(juzList, id: \.self) { juz in
                            row(number: juz, title: "Juz \(juz)", detail: "", trailing: "", current: juz == model.pageInfo?.juz) {
                                model.overlay = nil
                                model.goTo(juz: juz)
                            }
                            .id(juz)
                        }
                    }
                    }
                }
                .onAppear { proxy.scrollTo(model.currentSurah?.number ?? 1, anchor: .center) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.chrome)
        .onAppear { searchFocused = true }
        .onChange(of: mode) { query = "" }
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
            model.overlay = nil
            model.goTo(surah: surah.number)
        } else if mode == .juz, let juz = juzList.first {
            model.overlay = nil
            model.goTo(juz: juz)
        }
    }

    private func row(number: Int, title: String, detail: String, trailing: String, current: Bool,
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

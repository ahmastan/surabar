import Annotations
import MushafRendering
import SwiftUI

/// Bookmarks, highlights, and notes, each listed in reading order. Clicking an entry goes to its ayah.
struct AnnotationsPanel: View {
    let model: ReaderModel
    let annotations: AnnotationStore
    let palette: ReaderPalette
    @State private var tab = Tab.bookmarks

    enum Tab: String, CaseIterable {
        case bookmarks = "Bookmarks", highlights = "Highlights", notes = "Notes"
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch tab {
                    case .bookmarks:
                        ForEach(annotations.bookmarks.keys.sorted(), id: \.self) { ayah in
                            BookmarkRow(ayah: ayah, entry: annotations.bookmarks[ayah]!, model: model, annotations: annotations, palette: palette)
                        }
                    case .highlights:
                        ForEach(annotations.highlights.keys.sorted(), id: \.self) { ayah in
                            row(ayah, detail: model.library?.translation?.text(for: ayah) ?? "", lines: 1) {
                                Circle().fill(Color(nsColor: annotations.highlights[ayah]!.color.swatch)).frame(width: 10, height: 10)
                            } delete: { annotations.setHighlight(ayah, nil) }
                        }
                    case .notes:
                        ForEach(annotations.notes.keys.sorted(), id: \.self) { ayah in
                            row(ayah, detail: annotations.notes[ayah]!.text, lines: 2) {
                                Image(systemName: "note.text").foregroundStyle(palette.accent)
                            } delete: { annotations.setNote(ayah, "") }
                        }
                    }
                }
            }
            .overlay { if isEmpty { emptyState } }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.chrome)
    }

    private var isEmpty: Bool {
        switch tab {
        case .bookmarks: annotations.bookmarks.isEmpty
        case .highlights: annotations.highlights.isEmpty
        case .notes: annotations.notes.isEmpty
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: tab == .bookmarks ? "bookmark" : tab == .highlights ? "highlighter" : "note.text")
                .font(.system(size: 24, weight: .light))
            Text("No \(tab.rawValue.lowercased()) yet").font(.headline)
            Text(tab == .bookmarks ? "Right-click an ayah, or select it and press B." : "Right-click an ayah to add one.")
                .font(.caption)
        }
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.center)
    }

    private func row(_ ayah: AyahKey, detail: String, lines: Int, @ViewBuilder icon: () -> some View,
                     delete: @escaping () -> Void) -> some View {
        AnnotationRow(ayah: ayah, surah: model.store?.surah(ayah.surah)?.nameSimple ?? "", palette: palette, open: { open(ayah) },
                      delete: delete) {
            HStack(alignment: .top, spacing: 8) {
                icon().frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    title(ayah)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(palette.secondary).lineLimit(lines)
                    }
                }
            }
        }
    }

    private func title(_ ayah: AyahKey) -> some View {
        HStack(spacing: 6) {
            Text(ayah.description).font(.callout.weight(.semibold)).monospacedDigit()
            Text(model.store?.surah(ayah.surah)?.nameSimple ?? "").font(.caption).foregroundStyle(palette.secondary)
        }
    }

    private func open(_ ayah: AyahKey) {
        model.overlay = nil
        model.goTo(ayah)
    }
}

/// A bookmark with its label, which can be edited in place.
private struct BookmarkRow: View {
    let ayah: AyahKey
    let entry: BookmarkEntry
    let model: ReaderModel
    let annotations: AnnotationStore
    let palette: ReaderPalette
    @State private var label = ""
    @FocusState private var editing: Bool

    var body: some View {
        AnnotationRow(ayah: ayah, surah: model.store?.surah(ayah.surah)?.nameSimple ?? "", palette: palette,
                      open: { model.overlay = nil; model.goTo(ayah) }, delete: { annotations.removeBookmark(ayah) }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bookmark.fill").foregroundStyle(palette.accent).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ayah.description).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(model.store?.surah(ayah.surah)?.nameSimple ?? "").font(.caption).foregroundStyle(palette.secondary)
                    }
                    TextField("Add a label", text: $label)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .focused($editing)
                        .onSubmit(save)
                        .onChange(of: editing) { if !editing { save() } }
                }
            }
        }
        .onAppear { label = entry.label }
    }

    private func save() {
        if label != entry.label { annotations.setBookmark(ayah, label: label) }
    }
}

/// A list row: clicking opens the ayah; the trash button (shown on hover) and the context menu delete.
private struct AnnotationRow<Content: View>: View {
    let ayah: AyahKey
    let surah: String
    let palette: ReaderPalette
    let open: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: delete) {
                Image(systemName: "trash").font(.caption).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Delete")
            .accessibilityLabel("Delete \(ayah.description)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(hovering ? palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Go to \(ayah.description)", action: open)
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(surah) \(ayah.description)")
        .accessibilityAction(named: "Go to ayah", open)
    }
}

/// Writing or editing the note on an ayah, in a card over the page.
struct NoteEditor: View {
    let ayah: AyahKey
    let model: ReaderModel
    let annotations: AnnotationStore
    let palette: ReaderPalette
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Note").font(.headline)
                Text("\(model.store?.surah(ayah.surah)?.nameSimple ?? "") \(ayah.description)").foregroundStyle(palette.secondary)
                Spacer()
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(palette.page, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.secondary.opacity(0.3)))
                .frame(height: 120)
                .focused($focused)
            HStack {
                if annotations.notes[ayah] != nil {
                    Button("Delete Note", role: .destructive) {
                        annotations.setNote(ayah, "")
                        model.overlay = nil
                    }
                }
                Spacer()
                Button("Cancel") { model.overlay = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    annotations.setNote(ayah, text)
                    model.overlay = nil
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Save (⌘↩)")
            }
        }
        .padding(12)
        .background(palette.chrome, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear {
            text = annotations.notes[ayah]?.text ?? ""
            focused = true
        }
    }
}

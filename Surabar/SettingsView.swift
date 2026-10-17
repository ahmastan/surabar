import MushafRendering
import SwiftUI

/// Settings, shown in place of the reader content in the popover or detached window.
struct SettingsView: View {
    @Bindable var state: AppState
    let model: ReaderModel
    let palette: ReaderPalette
    /// Opens the colour panel for the custom accent.
    let editCustomAccent: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { state.isShowingSettings = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Return to the reader (Esc)")
            }
            .padding(.horizontal, 12)
            .frame(height: ReaderLayout.headerHeight)
            tabs
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state.settingsTab {
                    case .appearance: appearance
                    case .reading: reading
                    case .player: player
                    case .general: general
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The reader resizes to this height, so the window ends at the last setting.
                .background(GeometryReader { Color.clear.preference(key: SettingsContentHeight.self, value: $0.size.height) })
            }
            .onPreferenceChange(SettingsContentHeight.self) { height in
                let tab = state.settingsTab
                if abs((state.settingsContentHeights[tab] ?? 0) - height) > 0.5 { state.settingsContentHeights[tab] = height }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = state.settingsTab == tab
                Button { state.settingsTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 17)).frame(height: 20)
                        Text(tab.title).font(.caption)
                    }
                    .foregroundStyle(selected ? palette.accent : palette.secondary)
                    .frame(width: 74, height: 46)
                    .background(selected ? palette.secondary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ReaderLayout.settingsTabsHeight, alignment: .top)
    }

    // MARK: Appearance

    @ViewBuilder private var appearance: some View {
        SettingsGroup(palette: palette) {
            SettingsRow("Theme", palette: palette, stacked: true) {
                segmented($state.theme, ReaderTheme.allCases, title: \.title)
            }
            Divider()
            SettingsRow("Accent colour", value: state.accent.title, palette: palette, stacked: true) {
                AccentSwatches(state: state, palette: palette, editCustom: editCustomAccent)
            }
            Divider()
            SettingsRow("Size", palette: palette, stacked: true,
                        footnote: "Keys 1, 2, and 3 also choose a size while the reader is open.") {
                segmented($state.size, ReaderSize.allCases, title: \.title)
            }
        }
    }

    // MARK: Reading

    @ViewBuilder private var reading: some View {
        SettingsGroup(palette: palette) {
            if let layouts = model.store?.layouts, layouts.count > 1 {
                // Switching keeps the selected ayah in view.
                SettingsRow("Script", palette: palette, stacked: true,
                            footnote: "Uthmani is the 15-line Madani print; IndoPak is the 15-line Qudratullah print.") {
                    Picker("Script", selection: Binding(get: { state.script }, set: { model.switchScript(to: $0) })) {
                        // Uthmani, the default, comes first.
                        ForEach(layouts.sorted { $0.id == "uthmani" && $1.id != "uthmani" }, id: \.id) {
                            Text($0.id == "indopak" ? "IndoPak" : "Uthmani").tag($0.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
            }
            SettingsRow("Show translation", palette: palette,
                        footnote: translationFootnote) {
                Toggle("Show translation", isOn: $state.showTranslation).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var translationFootnote: String {
        let name = model.library?.translation.map { "\($0.name), " } ?? ""
        return "\(name)below the page in \"Quran + player\" mode."
    }

    // MARK: Player

    @ViewBuilder private var player: some View {
        SettingsGroup(palette: palette) {
            SettingsRow("Skip buttons move by", palette: palette, stacked: true,
                        footnote: "The outer buttons beside previous and next ayah.") {
                segmented($state.skipUnit, SkipUnit.allCases, title: \.title)
            }
        }
        SettingsGroup(title: "Loop", palette: palette) {
            SettingsRow("Repeat", palette: palette) {
                Picker("Repeat", selection: $state.repeatCount) {
                    ForEach(AppState.repeatCounts, id: \.self) { count in
                        Text(count == 0 ? "Until stopped" : "\(count) times").tag(count)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            SettingsRow("Pause between repeats", palette: palette,
                        footnote: "The Loop button's defaults: each ayah, or the whole surah or page, plays this many times.") {
                Picker("Pause between repeats", selection: $state.repeatPause) {
                    ForEach(0 ... 5, id: \.self) { seconds in
                        Text(seconds == 0 ? "None" : "\(seconds) s").tag(Double(seconds))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        SettingsGroup(palette: palette) {
            SettingsRow("Show", palette: palette, stacked: true,
                        footnote: "\"Player only\" shows just the recitation controls in a compact window.") {
                segmented($state.viewMode, ReaderViewMode.allCases, title: \.title)
            }
        }
        SettingsGroup(title: "Window", palette: palette) {
            SettingsRow("Keep detached window on top", palette: palette) {
                Toggle("Keep detached window on top", isOn: $state.keepOnTop).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func segmented<Value: Hashable>(_ selection: Binding<Value>, _ values: [Value], title: KeyPath<Value, String>) -> some View {
        Picker("", selection: selection) {
            ForEach(values, id: \.self) { Text($0[keyPath: title]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

private struct SettingsContentHeight: PreferenceKey {
    static let defaultValue = 0.0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

/// The accent choices: follow system, the eight macOS accent colours, and a custom colour.
private struct AccentSwatches: View {
    let state: AppState
    let palette: ReaderPalette
    let editCustom: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(ReaderAccent.allCases) { accent in
                Button {
                    state.accent = accent
                    if accent == .custom { editCustom() }
                } label: {
                    swatch(accent)
                }
                .buttonStyle(.plain)
                .help(accent == .custom ? "Custom colour…" : accent.title)
                .accessibilityLabel(accent == .custom ? "Custom colour" : accent.title)
                .accessibilityAddTraits(state.accent == accent ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func swatch(_ accent: ReaderAccent) -> some View {
        let selected = state.accent == accent
        return ZStack {
            switch accent {
            case .system:
                // As in System Settings, "follow system" is drawn as a multicolour swatch.
                Circle().fill(AngularGradient(colors: [.blue, .purple, .pink, .red, .orange, .yellow, .green, .blue], center: .center))
            case .custom:
                Circle().fill(Color(nsColor: ReaderPalette.color(for: .custom, custom: state.customAccent)))
                Circle().strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center), lineWidth: 2.5)
                Image(systemName: "eyedropper").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            default:
                Circle().fill(Color(nsColor: ReaderPalette.color(for: accent, custom: state.customAccent)))
            }
            Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
            if selected && accent != .custom { Circle().fill(.white).frame(width: 6, height: 6) }
        }
        .frame(width: 18, height: 18)
        .padding(2.5)
        .overlay(Circle().strokeBorder(selected ? palette.secondary.opacity(0.7) : .clear, lineWidth: 1.5))
        .contentShape(Circle())
    }
}

/// A titled group of rows on a rounded card, as in System Settings.
struct SettingsGroup<Content: View>: View {
    var title: String?
    let palette: ReaderPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(palette.page, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.secondary.opacity(0.18), lineWidth: 0.5))
        }
    }
}

/// A setting: its label beside the control, or above it for wide controls, with an optional footnote.
struct SettingsRow<Control: View>: View {
    let label: String
    var value: String?
    let palette: ReaderPalette
    var stacked = false
    var footnote: String?
    @ViewBuilder let control: Control

    init(_ label: String, value: String? = nil, palette: ReaderPalette, stacked: Bool = false, footnote: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.label = label
        self.value = value
        self.palette = palette
        self.stacked = stacked
        self.footnote = footnote
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if stacked {
                HStack {
                    Text(label)
                    Spacer()
                    if let value { Text(value).foregroundStyle(palette.secondary) }
                }
                control
            } else {
                HStack {
                    Text(label)
                    Spacer(minLength: 12)
                    control
                }
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }
}

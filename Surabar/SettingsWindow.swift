import AppKit
import MushafRendering
import SwiftUI

/// The Settings window. Managed directly because a menu-bar-only app has no app menu to open it from.
@MainActor
final class SettingsWindowController {
    private let state: AppState
    private let model: ReaderModel
    private var window: NSWindow?

    init(state: AppState, model: ReaderModel) {
        self.state = state
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state, model: model)))
        window.title = "Surabar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SurabarSettingsWindow")
        return window
    }
}

/// Settings. Recitation and integration settings arrive with their phases.
struct SettingsView: View {
    @Bindable var state: AppState
    let model: ReaderModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $state.theme) {
                    ForEach(ReaderTheme.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $state.size) {
                    ForEach(ReaderSize.allCases, id: \.self) { size in
                        Text("\(size.title) (\(Int(size.width)) pt)").tag(size)
                    }
                }
            }
            Section("Reading") {
                if let layouts = model.store?.layouts, layouts.count > 1 {
                    // Switching keeps the selected ayah in view.
                    Picker("Script", selection: Binding(get: { state.script }, set: { model.switchScript(to: $0) })) {
                        ForEach(layouts, id: \.id) { Text($0.id == "indopak" ? "IndoPak" : "Uthmani").tag($0.id) }
                    }
                }
                Toggle("Show translation strip", isOn: $state.showTranslation)
            }
            Section("Window") {
                Toggle("Keep detached window on top", isOn: $state.keepOnTop)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

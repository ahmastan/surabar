import AppKit
import MushafRendering
import SwiftUI

/// The Settings window. Managed directly because a menu-bar-only app has no app menu to open it from.
@MainActor
final class SettingsWindowController {
    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state)))
        window.title = "Surabar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SurabarSettingsWindow")
        return window
    }
}

/// Settings skeleton for Phase 1. Reading, recitation, and integration settings arrive with their phases.
struct SettingsView: View {
    @Bindable var state: AppState

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

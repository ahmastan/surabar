import MushafRendering
import SwiftUI

struct ReaderActions {
    let detach: () -> Void
    let attach: () -> Void
    let openSettings: () -> Void
}

/// The reader layout: navigation header, page, optional translation strip, and player.
/// Phase 1 shell: the page, translation, and player areas are placeholders until their phases.
struct ReaderView: View {
    let state: AppState
    let actions: ReaderActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            page
            if state.showTranslation {
                Divider()
                translation
            }
            Divider()
            player
        }
        .background(palette.chrome)
        .foregroundStyle(palette.ink)
    }

    private var palette: ReaderPalette { ReaderPalette(theme: state.theme) }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Surabar").font(.headline)
                Text("\(state.size.title) · \(Int(state.size.width)) pt").font(.caption).foregroundStyle(palette.secondary)
            }
            Spacer()
            if state.isDetached {
                headerButton("Return to menu bar", symbol: "menubar.arrow.up.rectangle", action: actions.attach)
            } else {
                headerButton("Detach window", symbol: "macwindow.on.rectangle", action: actions.detach)
            }
            headerButton("Settings", symbol: "gearshape", action: actions.openSettings)
        }
        .padding(.horizontal, 12)
        .frame(height: ReaderLayout.headerHeight)
    }

    private func headerButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var page: some View {
        ZStack {
            palette.page
            VStack(spacing: 6) {
                Image(systemName: "text.book.closed").font(.system(size: 28, weight: .light))
                Text("Mushaf page").font(.headline)
                Text("15-line pages are rendered here from Phase 2.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.secondary)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var translation: some View {
        Text("Translation strip (Phase 2)")
            .font(.callout)
            .foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: ReaderLayout.translationHeight)
    }

    private var player: some View {
        HStack(spacing: 14) {
            Text("Recitation (Phase 3)").font(.callout).foregroundStyle(palette.secondary)
            Spacer()
            Image(systemName: "backward.end.fill")
            Image(systemName: "play.circle.fill").font(.system(size: 30))
            Image(systemName: "forward.end.fill")
        }
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .frame(height: ReaderLayout.playerHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recitation controls, not available yet")
    }
}

/// Theme colours. System, Light, and Dark follow the window appearance; Sepia uses fixed colours.
struct ReaderPalette {
    let theme: ReaderTheme

    var chrome: Color { theme == .sepia ? Color(red: 0.933, green: 0.894, blue: 0.812) : Color(nsColor: .windowBackgroundColor) }
    var page: Color { theme == .sepia ? Color(red: 0.973, green: 0.941, blue: 0.871) : Color(nsColor: .textBackgroundColor) }
    var ink: Color { theme == .sepia ? Color(red: 0.18, green: 0.141, blue: 0.086) : .primary }
    var secondary: Color { theme == .sepia ? Color(red: 0.416, green: 0.353, blue: 0.259) : .secondary }
}

import AppKit
import SwiftUI

/// The material behind controls and the window, chosen in Settings › Appearance.
enum GlassStyle: String, CaseIterable, Identifiable {
    /// Liquid Glass on macOS 26 and later, which follows System Settings › Appearance › Liquid Glass and
    /// Reduce Transparency; the frosted materials on earlier versions.
    case system
    /// Apple's regular Liquid Glass (macOS 26 and later).
    case glass
    /// Apple's standard frosted materials, as in macOS 14 and 15.
    case frosted

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .glass: "Glass"
        case .frosted: "Frosted"
        }
    }

    /// Liquid Glass is available from macOS 26.
    static var isGlassAvailable: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// What is drawn: Liquid Glass when chosen (or by the system) and available, otherwise frosted.
    var usesGlass: Bool {
        self != .frosted && Self.isGlassAvailable
    }
}

/// The surface behind a group of controls or an overlay: Apple's Liquid Glass (`glassEffect`, regular
/// variant) or a standard frosted material, in the given shape. Interactive glass reacts to the pointer.
/// See "Applying Liquid Glass to custom views" in Apple's documentation.
struct Surface<S: Shape>: ViewModifier {
    let style: GlassStyle
    let shape: S
    var interactive = false
    var tint: Color?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), style.usesGlass {
            content.glassEffect(glass, in: shape)
        } else {
            // A tinted surface is the main action; frosted, it is a solid fill so its label stays legible.
            content
                .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

extension View {
    func surface(_ style: GlassStyle, in shape: some Shape, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(Surface(style: style, shape: shape, interactive: interactive, tint: tint))
    }

    /// Groups glass surfaces so they render together and blend or morph into one another, as Apple advises.
    @ViewBuilder func glassGroup(_ style: GlassStyle, spacing: CGFloat? = nil) -> some View {
        if style.usesGlass, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// One set of animations for the whole app. With Reduce Motion, movement is replaced by a fade or nothing.
enum Motion {
    /// Overlays, the settings switch, view changes.
    static let standard = Animation.smooth(duration: 0.28)
    /// Small state changes: buttons, badges, the "Back to playing" pill.
    static let quick = Animation.smooth(duration: 0.18)

    static func standard(reduceMotion: Bool) -> Animation? { reduceMotion ? .easeInOut(duration: 0.15) : standard }

    /// An overlay arriving from the top, or fading in place with Reduce Motion.
    static func overlay(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12))
    }
}

/// Buttons sharing one surface, as related toolbar items do in macOS 26 (Safari, Finder, Music): one
/// capsule of glass (or frosted material), in which each button highlights under the pointer.
struct ControlCluster<Content: View>: View {
    let style: GlassStyle
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .surface(style, in: Capsule())
            .glassGroup(style)
    }
}

/// A button inside a `ControlCluster`: an icon that highlights on hover and darkens when pressed.
struct ClusterButtonStyle: ButtonStyle {
    var width: CGFloat = 30
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ClusterButton(configuration: configuration, width: width, height: height)
    }

    private struct ClusterButton: View {
        let configuration: Configuration
        let width: CGFloat
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(minWidth: width, minHeight: height)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.07 : 0)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }
}

/// The main button of a card or sheet: Apple's prominent glass button on macOS 26, otherwise the
/// standard prominent button.
struct ProminentButton: ViewModifier {
    let glass: GlassStyle

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), glass.usesGlass {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

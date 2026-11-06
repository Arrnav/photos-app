import SwiftUI
import UIKit

enum GlassStyle {
    case regular
    case clear
    case dark
}

/// Liquid Glass in SwiftUI (iOS 26), with a material fallback on earlier versions.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = true, style: GlassStyle = .regular) -> some View {
        if #available(iOS 26.0, *) {
            let glass: SwiftUI.Glass = switch style {
            case .regular: .regular
            // Clearer glass: more of the photos show through (the floating bar).
            case .clear: .clear.tint(Color(.systemBackground).opacity(0.18))
            // Clear glass with a dark tint, for buttons over the dark Library band.
            case .dark: .clear.tint(.black.opacity(0.28))
            }
            self.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            self.background(style == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
        }
    }

    /// Lets glass pieces morph into each other (Library bar ↔ time scale).
    @ViewBuilder
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend and morph together (iOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A dark band at the top of a screen, blurred more at the very top and fading out
/// downwards, so white titles read over photos (the Library header).
struct TopScrim: View {
    var height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            // Full blur at the top, easing out downwards.
            VariableBlur()
                .mask(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom))
            // A lighter shade than before (0.42 at the top), so the photos show through a little.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .black.opacity(0.15), location: 0.55),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// A plain blur (masked by `TopScrim` to fade out).
private struct VariableBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

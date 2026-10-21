import SwiftUI

// Liquid Glass (iOS 26) with a frosted-material fallback for iOS 17–18.
// `#if compiler(>=6.2)` keeps the project building with older Xcode versions too.

extension View {
    /// Liquid Glass background in `shape`.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.frostedFallback(shape, tint: tint)
        }
        #else
        self.frostedFallback(shape, tint: tint)
        #endif
    }

    /// Capsule-shaped interactive glass, the default for buttons and chips.
    func glassCapsule(tint: Color? = nil) -> some View {
        glass(Capsule(), tint: tint, interactive: true)
    }

    func glassCircle(tint: Color? = nil) -> some View {
        glass(Circle(), tint: tint, interactive: true)
    }

    /// Prominent glass button style (falls back to a filled button).
    @ViewBuilder
    func prominentGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    private func frostedFallback<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill((tint ?? .clear).opacity(0.35)))
            .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }
}

/// Groups glass elements so they blend and morph into each other on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

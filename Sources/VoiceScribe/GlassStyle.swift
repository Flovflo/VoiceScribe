import SwiftUI

/// Shared native surfaces, with system-material support on macOS 14 and 15.
private struct VoiceScribeGlassSurface<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
        } else if #available(macOS 26, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(glass.interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

extension View {
    func voiceScribeGlass<S: Shape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        modifier(VoiceScribeGlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    @ViewBuilder
    func voiceScribeGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }
}

struct VoiceScribeGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

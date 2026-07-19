import SwiftUI

/// Shared "liquid glass" surface styling: a frosted material, a soft edge
/// highlight (top-lit), and a neutral shadow — no colored glows.
extension View {
    /// Frosted capsule for the floating tool bar.
    func glassCapsule() -> some View {
        clipShape(Capsule(style: .continuous))
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.06), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }

    /// Frosted rounded panel for popovers and floating cards.
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.05), .white.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
    }
}

/// Dark, near-black backdrop the frosted glass reads against.
struct EditorBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.06, green: 0.06, blue: 0.08), Color(red: 0.02, green: 0.02, blue: 0.03)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .top, startRadius: 0, endRadius: 520
            )
        )
        .ignoresSafeArea()
    }
}

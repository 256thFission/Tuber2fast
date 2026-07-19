import SwiftUI

/// Clean liquid-glass styling: a light frosted material with a bright hairline
/// edge and a soft neutral shadow. No grain, no colored glows.
extension View {
    func glassCapsule() -> some View {
        clipShape(Capsule(style: .continuous))
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }

    func frostedGlass(cornerRadius: CGFloat = 26) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.3), radius: 24, y: 14)
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

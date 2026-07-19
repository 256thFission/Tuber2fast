import SwiftUI
import UIKit

/// Shared "liquid glass" styling. Two families:
/// - `glassCapsule()` — light, translucent bar for the floating tool bar.
/// - `frostedGlass(_:)` — matte, grainy frosted panel (sidebar, popups, cards).
/// All shadows are neutral; no colored glows.
extension View {
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

    /// Matte frosted panel: opaque-ish material + soft sheen + fine grain.
    func frostedGlass(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background { FrostSurface().clipShape(shape) }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.05), .white.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.38), radius: 26, y: 14)
    }
}

/// The frosted fill: material base, a top-lit sheen, and a subtle noise grain.
/// Use inside a `.background { }` and clip it to your own shape.
struct FrostSurface: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [.white.opacity(0.12), .white.opacity(0.02), .clear],
                startPoint: .top, endPoint: .bottom
            )
            NoiseTextureView()
                .opacity(0.05)
                .blendMode(.overlay)
        }
    }
}

/// Tiled monochrome noise for the frosted-glass grain.
struct NoiseTextureView: View {
    var body: some View {
        Image(uiImage: NoiseTexture.image)
            .resizable(resizingMode: .tile)
            .saturation(0)
            .allowsHitTesting(false)
    }
}

enum NoiseTexture {
    static let image: UIImage = generate()

    private static func generate() -> UIImage {
        let side = 110
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            for x in 0..<side {
                for y in 0..<side {
                    let v = CGFloat.random(in: 0...1)
                    ctx.cgContext.setFillColor(UIColor(white: v, alpha: 1).cgColor)
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
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

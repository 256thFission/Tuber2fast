import SwiftUI

/// Minimal, soothing backdrop: black with a few very slow, breathing white/grey
/// blotches. Touching an exposed area sends out a soft ripple. Frosted panels
/// blur this, which is what gives them their glassy look.
struct AmbientBackground: View {
    private struct Blob {
        let baseX, baseY, radius, driftX, driftY, driftSpeed, breathSpeed, phase, alpha: CGFloat
    }
    private struct Ripple: Identifiable {
        let id = UUID()
        let center: CGPoint
        let start: TimeInterval
    }

    @State private var ripples: [Ripple] = []
    private let startDate = Date()

    private let blobs: [Blob] = [
        Blob(baseX: 0.20, baseY: 0.18, radius: 300, driftX: 55, driftY: 40, driftSpeed: 0.06, breathSpeed: 0.50, phase: 0.0, alpha: 0.16),
        Blob(baseX: 0.82, baseY: 0.14, radius: 260, driftX: 48, driftY: 52, driftSpeed: 0.05, breathSpeed: 0.42, phase: 1.4, alpha: 0.10),
        Blob(baseX: 0.72, baseY: 0.72, radius: 340, driftX: 66, driftY: 58, driftSpeed: 0.045, breathSpeed: 0.37, phase: 2.6, alpha: 0.13),
        Blob(baseX: 0.24, baseY: 0.82, radius: 280, driftX: 52, driftY: 44, driftSpeed: 0.07, breathSpeed: 0.55, phase: 3.7, alpha: 0.09),
        Blob(baseX: 0.50, baseY: 0.46, radius: 380, driftX: 40, driftY: 66, driftSpeed: 0.038, breathSpeed: 0.31, phase: 5.0, alpha: 0.07),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(startDate)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 60))
                    for blob in blobs {
                        let cx = blob.baseX * size.width + CGFloat(sin(t * blob.driftSpeed + blob.phase)) * blob.driftX
                        let cy = blob.baseY * size.height + CGFloat(cos(t * blob.driftSpeed * 0.9 + blob.phase)) * blob.driftY
                        let breath = 1 + 0.14 * CGFloat(sin(t * blob.breathSpeed + blob.phase))
                        let r = blob.radius * breath
                        let a = blob.alpha * (0.72 + 0.28 * CGFloat(sin(t * blob.breathSpeed * 0.8 + blob.phase)))
                        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                        let shading = GraphicsContext.Shading.radialGradient(
                            Gradient(colors: [Color.white.opacity(Double(max(a, 0))), .clear]),
                            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r
                        )
                        layer.fill(Path(ellipseIn: rect), with: shading)
                    }
                }

                for ripple in ripples {
                    let age = t - ripple.start
                    guard age >= 0, age <= 2.0 else { continue }
                    let progress = age / 2.0
                    let rr = 20 + progress * 210
                    let alpha = (1 - progress) * 0.22
                    let rect = CGRect(x: ripple.center.x - rr, y: ripple.center.y - rr, width: rr * 2, height: rr * 2)
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(alpha)),
                               lineWidth: 2 * (1 - progress) + 0.5)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in addRipple(at: value.location) }
        )
    }

    private func addRipple(at point: CGPoint) {
        let now = Date().timeIntervalSince(startDate)
        ripples.append(Ripple(center: point, start: now))
        if ripples.count > 12 { ripples = Array(ripples.suffix(12)) }
    }
}

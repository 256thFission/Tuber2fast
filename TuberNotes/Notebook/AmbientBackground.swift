import SwiftUI
import UIKit

/// Process-stable clock. SwiftUI re-creates `AmbientBackground` on every publish
/// from the view model (zoom, drawing, page changes), and a per-instance
/// `Date()` "start" would reset the animation phase each time — that was the
/// "background jumps when you zoom/pan" bug. Anchoring to one static epoch keeps
/// the motion continuous no matter how often the view is rebuilt.
enum AmbientClock {
    static let epoch = Date()
    static var now: TimeInterval { Date().timeIntervalSince(epoch) }
}

/// A ripple spawned by a touch anywhere over the editor.
struct AmbientRipple: Identifiable {
    let id = UUID()
    let center: CGPoint
    let start: TimeInterval   // seconds since AmbientClock.epoch
}

/// Shared, observable ripple source. A passthrough touch layer higher in the
/// view tree feeds touches here, and the backdrop (at the bottom of the ZStack)
/// renders them — so ripples appear under the pen/finger, not just in the margins.
@MainActor
final class AmbientRippleModel: ObservableObject {
    @Published private(set) var ripples: [AmbientRipple] = []
    private var lastPoint: CGPoint = .zero
    private var lastTime: TimeInterval = -1
    private let lifetime: TimeInterval = 1.8

    func add(at point: CGPoint) {
        let now = AmbientClock.now
        // Throttle near-duplicate hit-tests from a single touch / hover stream.
        if now - lastTime < 0.05, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 16 {
            return
        }
        lastPoint = point
        lastTime = now
        ripples.removeAll { now - $0.start > lifetime }
        ripples.append(AmbientRipple(center: point, start: now))
        if ripples.count > 14 { ripples.removeFirst(ripples.count - 14) }
    }
}

/// Minimal, soothing backdrop: black with a few slow, breathing white/grey
/// blotches that drift around, plus soft ripples wherever the page is touched.
/// Frosted panels blur this, which is what gives them their glassy look.
struct AmbientBackground: View {
    @ObservedObject var rippleModel: AmbientRippleModel

    private struct Blob {
        let baseX, baseY, radius, driftX, driftY, driftSpeed, breathSpeed, phase, alpha: CGFloat
    }

    // Wider drift + slightly quicker so the motion reads a touch more, still calm.
    private let blobs: [Blob] = [
        Blob(baseX: 0.20, baseY: 0.18, radius: 320, driftX: 86, driftY: 64, driftSpeed: 0.075, breathSpeed: 0.55, phase: 0.0, alpha: 0.30),
        Blob(baseX: 0.82, baseY: 0.14, radius: 280, driftX: 74, driftY: 80, driftSpeed: 0.063, breathSpeed: 0.47, phase: 1.4, alpha: 0.20),
        Blob(baseX: 0.72, baseY: 0.72, radius: 360, driftX: 98, driftY: 88, driftSpeed: 0.057, breathSpeed: 0.41, phase: 2.6, alpha: 0.26),
        Blob(baseX: 0.24, baseY: 0.82, radius: 300, driftX: 80, driftY: 68, driftSpeed: 0.088, breathSpeed: 0.60, phase: 3.7, alpha: 0.18),
        Blob(baseX: 0.50, baseY: 0.46, radius: 420, driftX: 64, driftY: 98, driftSpeed: 0.049, breathSpeed: 0.35, phase: 5.0, alpha: 0.15),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(AmbientClock.epoch)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 48))
                    for blob in blobs {
                        let cx = blob.baseX * size.width + CGFloat(sin(t * blob.driftSpeed + blob.phase)) * blob.driftX
                        let cy = blob.baseY * size.height + CGFloat(cos(t * blob.driftSpeed * 0.9 + blob.phase)) * blob.driftY
                        let breath = 1 + 0.20 * CGFloat(sin(t * blob.breathSpeed + blob.phase))
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

                for ripple in rippleModel.ripples {
                    let age = t - ripple.start
                    guard age >= 0, age <= 1.8 else { continue }
                    let p = age / 1.8
                    let rr = 16 + p * 240
                    let rect = CGRect(x: ripple.center.x - rr, y: ripple.center.y - rr, width: rr * 2, height: rr * 2)

                    // Soft glow that fades outward, then a crisper ring on top.
                    let fillAlpha = (1 - p) * 0.12
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(fillAlpha), .clear]),
                            center: ripple.center, startRadius: rr * 0.15, endRadius: rr
                        )
                    )
                    let ringAlpha = (1 - p) * 0.32
                    ctx.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(ringAlpha)),
                        lineWidth: 2 * (1 - p) + 0.5
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Full-screen, non-consuming touch observer. Its `UIView` reports every
/// touch-down location (finger or Pencil) and returns `nil` from `hitTest`, so
/// the touch still reaches the page/canvas underneath — nothing is intercepted.
/// This is how ripples can appear under the pen even though the drawing surface
/// captures its own touches.
struct AmbientTouchLayer: UIViewRepresentable {
    var onTouch: (CGPoint) -> Void

    func makeUIView(context: Context) -> PassthroughTouchView {
        let view = PassthroughTouchView()
        view.onTouch = onTouch
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: PassthroughTouchView, context: Context) {
        uiView.onTouch = onTouch
    }

    final class PassthroughTouchView: UIView {
        var onTouch: ((CGPoint) -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if bounds.contains(point) { onTouch?(point) }
            return nil   // never become the touch target — pass through
        }
    }
}

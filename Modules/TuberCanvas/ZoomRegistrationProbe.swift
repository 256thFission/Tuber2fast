import TuberCore
import UIKit

/// Measures whether the mirrored backdrop and the ink actually agree, frame by
/// frame, through a pinch.
///
/// **A probe, not a mechanism.** It answers one question Phillip raised from the
/// device on 2026-08-07 — "every time I zoom in or out quickly it looks like the
/// ink is catching up to its scale on the images beneath it" — which has exactly
/// two candidate causes, and they need opposite fixes:
///
/// 1. **The mirror leads the ink.** `PageBackdrop.mirror` is driven from the
///    scroll view's *model* `zoomScale` and `contentOffset` with implicit
///    animation off, so it lands this frame. If `UIScrollView` is meanwhile
///    presenting a different scale — a rubber-band overshoot past the zoom
///    limits, or the bounce animating back after the fingers lift — then the
///    backdrop is at the final scale while the ink is still on its way there.
///    That is our defect, and the fix is ours.
/// 2. **PencilKit's ink raster is behind its own view.** Then the layer tree is
///    perfectly registered and the lag is inside PencilKit's rendering, where no
///    transform of ours can reach it.
///
/// The two are indistinguishable by eye and trivially distinguishable by
/// measurement: case 1 diverges in the layer tree, case 2 does not. So this
/// samples both sides — the *presented* transform of the scroll view's own
/// zooming view against the *model* values the mirror used — keeps the worst
/// disagreement of the pinch, and logs one line when the pinch ends. Nothing is
/// logged per frame and nothing is allocated per frame.
///
/// **Delete this once the verdict lands.** It earns its place only while the
/// question is open; a probe kept past its answer is cost with no reader.
@MainActor
final class ZoomRegistrationProbe {
    /// The view `UIScrollView` applies the zoom transform to. Handed over by
    /// `scrollViewDidEndZooming(_:with:atScale:)` — a public callback, so this
    /// reaches into no private hierarchy. Weak: PencilKit owns it.
    private weak var zoomView: UIView?

    private var samples = 0
    private var worstScaleRatio: Double = 1
    private var worstOffsetDrift: Double = 0
    private var sawAnimation = false

    /// The zoom view, learned from the scroll view's own delegate callback.
    func adopt(_ view: UIView?) {
        guard let view, zoomView !== view else { return }
        zoomView = view
        CanvasLog.event(.canvas, "zoom probe adopted \(type(of: view))")
    }

    /// One zoom frame. Runs on the frame path, so: no allocation, no logging,
    /// no publication — two presentation reads and some arithmetic, and an
    /// immediate return before the first pinch has handed over a zoom view.
    func sample(canvasView: UIScrollView, modelZoom: CGFloat, modelOffset: CGPoint) {
        guard let presented = zoomView?.layer.presentation() else { return }
        let presentedScale = Double(presented.affineTransform().a)
        let model = Double(modelZoom)
        guard model > 0, presentedScale > 0 else { return }

        samples += 1
        if presented.animationKeys()?.isEmpty == false { sawAnimation = true }

        let ratio = presentedScale / model
        if abs(ratio - 1) > abs(worstScaleRatio - 1) { worstScaleRatio = ratio }

        if let canvasPresented = canvasView.layer.presentation() {
            let drift = hypot(
                Double(canvasPresented.bounds.origin.x - modelOffset.x),
                Double(canvasPresented.bounds.origin.y - modelOffset.y)
            )
            worstOffsetDrift = max(worstOffsetDrift, drift)
        }
    }

    /// One line per pinch, at settle. Silent when the pinch produced no samples,
    /// so an ordinary pan never writes anything.
    func flush(_ reason: String, canvasView: UIScrollView) {
        guard samples > 0 else { return }
        // Two decimals of a ratio: 1.00 means the presented scale never
        // disagreed with the model the mirror used, which is the answer that
        // sends the investigation into PencilKit rather than into our transform.
        let ratio = (worstScaleRatio * 1000).rounded() / 1000
        CanvasLog.event(
            .canvas,
            "ZOOM PROBE \(reason) samples=\(samples) worstPresentedOverModel=\(ratio) "
                + "worstOffsetDriftPt=\((worstOffsetDrift * 10).rounded() / 10) "
                + "animating=\(sawAnimation) bouncingZoom=\(canvasView.isZoomBouncing) "
                + "zoom=\((Double(canvasView.zoomScale) * 100).rounded() / 100) "
                + "range=\((Double(canvasView.minimumZoomScale) * 100).rounded() / 100)"
                + "...\((Double(canvasView.maximumZoomScale) * 100).rounded() / 100)"
        )
        samples = 0
        worstScaleRatio = 1
        worstOffsetDrift = 0
        sawAnimation = false
    }

    /// Read by tests: the worst disagreement seen since the last flush.
    // Debug-only, as every `…ForTesting` member is; the reasoning is at
    // `EditorSession.staticRendererForTesting`.
    #if DEBUG
    var worstScaleRatioForTesting: Double { worstScaleRatio }
    var sampleCountForTesting: Int { samples }
    #endif
}

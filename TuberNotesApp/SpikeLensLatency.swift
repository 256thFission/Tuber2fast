// THROWAWAY SPIKE CODE — CanvasFeatureComplete device spike 2, "Lens latency".
//
// This file never merges to main as-is. It exists so Phillip can answer one
// question on a physical iPad (`Docs/Forks/CanvasFeatureComplete.md` —
// Rendering, "At settle: background decode, then swap"; Device spikes,
// item 2):
//
//   Do lens renders of a dense vector page arrive fast enough after a pinch
//   settles — or does the pooled tile grid get built?
//
// Everything here compiles only under TN_SPIKE_LENS (see `project.yml`,
// `TN_SPIKE_CONDITIONS`), in Debug or Release. With the flag off this file
// contributes nothing and the app behaves identically. With it on, the spike
// REPLACES the editor scene (`TuberNotesApp.swift`): it deliberately stands
// alone rather than instrumenting the live canvas, because base-and-lens
// integration is phase 3c proper and the canvas runtime files are owned by
// that phase. Do not combine TN_SPIKE_LENS with TN_SPIKE_MIRROR — the lens
// scene replaces the scene the mirror instruments.
//
// UNTHREADED — THIS SPIKE DOES NOT RUN AS IT STANDS.
//
// `TuberNotesApp.swift` used to carry the one `#if TN_SPIKE_LENS` hook that
// chose this scene over the editor's. It came out (Stage 2 item 12,
// `Docs/Forks/CanvasCompleteTodo.md`): dead by default, no device verdict
// coming, and a conditional at the app's entry point is read by everyone.
// Turning TN_SPIKE_LENS back on now compiles this file and shows nothing —
// the app still opens the editor.
//
// The hook cannot live in this file: only the `@main` App value can decide
// what the window group hosts. So the recipe, not a copy:
//
// TO RE-THREAD THIS SPIKE, reinstall one hook in
// `TuberNotesApp/TuberNotesApp.swift`, in `TuberNotesApp.body`'s
// `WindowGroup`, replacing the bare `EditorSceneView()` with:
//
//     #if TN_SPIKE_LENS
//     SpikeLensSceneView()
//     #else
//     EditorSceneView()
//     #endif
//
// Nothing else in the app ever named this file's types.
//
// The loop under measurement, exactly the fork doc's bullet: during a pinch
// the compositor scales the existing base texture (no decode is ever
// triggered by a gesture frame — the only per-tick code here is the scroll
// view's own). When the pinch SETTLES, the visible rect of the page is
// rasterized at the new scale off-main via `PDFPageRasterizer`, and the
// result is swapped in as `CALayer.contents` on main. Three timestamps —
// settle, decode-done, swap-committed — go out as one `CanvasLog` line per
// settle, never per frame, and `Tools/device`'s digest collects them:
//
//   Tools/device --release   with `TN_SPIKE_CONDITIONS = TN_SPIKE_LENS` in
//                            Local.xcconfig (remove it after)
//
// then pinch around the page; every settle prints a `SPIKE lens settled`
// line, and the digest of the capture lists them under "lens latency".
//
// The page is a dense synthetic worksheet — thousands of vector strokes and
// glyph runs authored at install — because the spike must run before any
// textbook import exists. That is a stand-in, said plainly: the verdict is
// owed on a real textbook page, on hardware, and this file claims no number.

#if TN_SPIKE_LENS

import SwiftUI
import TuberCore
import TuberModel
import TuberRender
import UIKit

/// The SwiftUI face of the spike, hosted by `TuberNotesApp` in place of the
/// editor scene. Lives in this file so the UIKit vocabulary stays inside the
/// one allowlisted spike file.
struct SpikeLensSceneView: View {
    var body: some View {
        SpikeLensRepresentable()
            .ignoresSafeArea()
    }
}

private struct SpikeLensRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SpikeLensController { SpikeLensController() }
    func updateUIViewController(_ controller: SpikeLensController, context: Context) {}
}

/// A zoomable page whose sharpness comes from base + lens, on plain
/// `CALayer.contents` — the fork doc's presumed structure, isolated from the
/// real canvas.
final class SpikeLensController: UIViewController, UIScrollViewDelegate {

    /// The page, in page points. Canonical letter geometry, matching what an
    /// imported worksheet page would carry.
    private let pageSize = CGSize(
        width: PageGeometry.canonical.width, height: PageGeometry.canonical.height
    )

    private let scrollView = UIScrollView()
    /// The zooming view, page-sized in points; the scroll view scales it.
    private let pageView = UIView()
    /// The whole page at fit-width detail. Scaled soft during a pinch —
    /// exactly as every PDF viewer on iOS does — until the lens lands.
    private let baseLayer = CALayer()
    /// The visible rect at settled detail, over the base. Its frame is set in
    /// page points; the zoom transform carries it, so its high-resolution
    /// contents render sharp.
    private let lensLayer = CALayer()

    /// The dense vector fixture, authored once at install.
    private var pdfBytes = Data()

    /// Stale-swap guard: a settle that starts a render bumps this, and a
    /// render that finishes into a newer generation discards itself. The
    /// discarded render is still logged — a lens that keeps arriving too late
    /// to be shown is precisely the observation this spike exists to make.
    private var lensGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray4

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.maximumZoomScale = 10 // what PKCanvasView clamps to; see phase 3b
        scrollView.contentSize = pageSize
        view.addSubview(scrollView)

        pageView.frame = CGRect(origin: .zero, size: pageSize)
        pageView.backgroundColor = .white
        scrollView.addSubview(pageView)

        baseLayer.frame = pageView.bounds
        baseLayer.magnificationFilter = .linear
        pageView.layer.addSublayer(baseLayer)

        lensLayer.isHidden = true
        lensLayer.magnificationFilter = .linear
        pageView.layer.addSublayer(lensLayer)

        // Fixture construction and the base render are install work, not an
        // interaction path.
        pdfBytes = Self.denseWorksheetPDF(pageSize: pageSize)
        CanvasLog.event(
            .canvas,
            "SPIKE lens installing: dense fixture pdf=\(pdfBytes.count) bytes, "
                + "page=\(Int(pageSize.width))x\(Int(pageSize.height)) pt; pinch and "
                + "release — every settle logs one 'SPIKE lens settled' line"
        )
        renderBase()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fitWidth = scrollView.bounds.width / pageSize.width
        guard fitWidth.isFinite, fitWidth > 0 else { return }
        if scrollView.minimumZoomScale != fitWidth {
            scrollView.minimumZoomScale = fitWidth
            scrollView.zoomScale = fitWidth
        }
    }

    private var displayScale: CGFloat {
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    private func renderBase() {
        let bytes = pdfBytes
        let scale = Double(scrollView.bounds.width / pageSize.width * displayScale)
        let level = scale.isFinite && scale > 0 ? scale : 2
        Task { [baseLayer] in
            do {
                let image = try await PDFPageRasterizer.rasterize(
                    bytes, sourcePageIndex: 0, pixelsPerPagePoint: level
                )
                baseLayer.contents = image
                CanvasLog.event(
                    .canvas,
                    "SPIKE lens base rendered at \(String(format: "%.2f", level)) px/pt "
                        + "(\(image.width)x\(image.height))"
                )
            } catch {
                CanvasLog.event(.canvas, "SPIKE lens base REFUSED: \(error)")
            }
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    /// The settle. Nothing happens during the pinch itself — the compositor
    /// scales the base — and this fires once when the gesture ends.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderLens(reason: "pinch")
    }

    /// A fling after a zoom moves the viewport off the lens; re-render at
    /// rest. Still never per frame — once per gesture end.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView.zoomScale > scrollView.minimumZoomScale { renderLens(reason: "pan") }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, scrollView.zoomScale > scrollView.minimumZoomScale {
            renderLens(reason: "pan")
        }
    }

    // MARK: - The measured loop

    private func renderLens(reason: String) {
        let settled = CACurrentMediaTime()
        lensGeneration += 1
        let generation = lensGeneration

        // The visible rect, in page points, clamped to the page: the
        // rasterizer refuses a rect past the edge, and rightly.
        let zoom = scrollView.zoomScale
        guard zoom > 0 else { return }
        let visible = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        ).intersection(CGRect(origin: .zero, size: pageSize))
        guard !visible.isEmpty else { return }

        let level = Double(zoom * displayScale)
        let bytes = pdfBytes

        Task {
            let image: CGImage
            do {
                // Off-main by construction: nonisolated async runs on the
                // generic executor, and `builtOffMain` in the log is the
                // observed fact, not the intention.
                image = try await PDFPageRasterizer.rasterize(
                    bytes, sourcePageIndex: 0, pixelsPerPagePoint: level, subRect: visible
                )
            } catch {
                CanvasLog.event(.canvas, "SPIKE lens render REFUSED: \(error)")
                return
            }
            let decoded = CACurrentMediaTime()

            await MainActor.run { [weak self] in
                guard let self else { return }
                let stale = generation != self.lensGeneration
                if !stale {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.lensLayer.contents = image
                    self.lensLayer.frame = visible
                    self.lensLayer.isHidden = false
                    CATransaction.commit()
                }
                let committed = CACurrentMediaTime()
                // One line per settle: the digest of a device capture picks
                // these up under "lens latency". settleToDecode is the time
                // the user sees a soft page; decodeToSwap is main-thread
                // hand-off; a stale swap was outrun by the next gesture.
                CanvasLog.event(
                    .canvas,
                    String(
                        format: "SPIKE lens settled reason=%@ zoom=%.2f level=%.2fpx/pt "
                            + "rect=%.0fx%.0f@(%.0f,%.0f) pixels=%dx%d "
                            + "settleToDecodeMs=%.1f decodeToSwapMs=%.1f totalMs=%.1f stale=%@",
                        reason, Double(zoom), level,
                        Double(visible.width), Double(visible.height),
                        Double(visible.minX), Double(visible.minY),
                        image.width, image.height,
                        (decoded - settled) * 1000,
                        (committed - decoded) * 1000,
                        (committed - settled) * 1000,
                        stale ? "true" : "false"
                    )
                )
            }
        }
    }

    // MARK: - The fixture

    /// A dense vector worksheet: a fine rule grid, thousands of short bezier
    /// strokes, and repeated glyph runs — a stand-in for a textbook page with
    /// enough path count to make CoreGraphics work for its living. Authored
    /// through `UIGraphicsPDFRenderer` because the fixture needs density, not
    /// exotic boxes; the rasterizer's own correctness is pinned elsewhere by
    /// byte-exact fixtures.
    static func denseWorksheetPDF(pageSize: CGSize) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext

            // Rule grid, fine enough to shimmer when soft.
            cg.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
            cg.setLineWidth(0.3)
            var y: CGFloat = 0
            while y <= bounds.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: bounds.width, y: y))
                y += 4
            }
            var x: CGFloat = 0
            while x <= bounds.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: bounds.height))
                x += 4
            }
            cg.strokePath()

            // Thousands of short curves. Deterministic, so two runs of the
            // spike rasterize the same page.
            var seed: UInt64 = 0x5DEECE66D
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max)
            }
            cg.setLineWidth(0.6)
            for stroke in 0..<4000 {
                cg.setStrokeColor(
                    UIColor(
                        hue: random(), saturation: 0.7, brightness: 0.45, alpha: 1
                    ).cgColor
                )
                let origin = CGPoint(x: random() * bounds.width, y: random() * bounds.height)
                cg.move(to: origin)
                cg.addCurve(
                    to: CGPoint(x: origin.x + (random() - 0.5) * 30, y: origin.y + (random() - 0.5) * 30),
                    control1: CGPoint(x: origin.x + (random() - 0.5) * 20, y: origin.y + (random() - 0.5) * 20),
                    control2: CGPoint(x: origin.x + (random() - 0.5) * 20, y: origin.y + (random() - 0.5) * 20)
                )
                cg.strokePath()
                _ = stroke
            }

            // Glyph runs: text is what a textbook page mostly is.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 6),
                .foregroundColor: UIColor.darkGray,
            ]
            let line = "The quick brown fox jumps over the lazy dog 0123456789 — " as NSString
            var textY: CGFloat = 2
            while textY < bounds.height {
                line.draw(at: CGPoint(x: 4, y: textY), withAttributes: attributes)
                textY += 9
            }
        }
    }
}

#endif

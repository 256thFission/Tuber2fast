// THROWAWAY SPIKE CODE — CanvasFeatureComplete device spike 1, "Mirror fidelity".
//
// This file never merges to main as-is. It exists so Phillip can answer two
// questions on a physical iPad (`Docs/Forks/CanvasFeatureComplete.md` —
// Rendering, without breaking the frame path; Device spikes, item 1):
//
//   A. Does a sibling view under a transparent `PKCanvasView`, mirrored by one
//      transform assignment per scroll tick from the existing delegate
//      callbacks, hold visual registration with ink at 120 Hz through pinch,
//      fling, and rubber-band? (The presumed winner.)
//   B. Does a subview inserted inside `PKCanvasView` beneath the ink survive a
//      first Pencil stroke at all? This branch carries the burden of proof:
//      this project already crashed UIKit in `_delayTouchesForEvent:` by
//      adding a subview to the canvas — the page boundary is a CALayer for
//      exactly that reason (see `PageCanvasController.pageBoundary`).
//
// Everything here compiles only under TN_SPIKE_MIRROR (see `project.yml`,
// `TN_SPIKE_CONDITIONS`). With the flag off this file contributes nothing and
// the app behaves identically. Variant selection is at launch, via the
// TN_SPIKE_MIRROR_VARIANT environment variable: unset or "sibling" runs A,
// "inside" runs B.
//
// The contract's frame-path rules apply even here, because latency is what is
// being measured: the per-tick path is one CATransform3D assignment plus a few
// scalar comparisons — no allocation, no publication, no logging. Logging
// happens only at install and at gesture end.

#if TN_SPIKE_MIRROR

import UIKit

/// The mirrored registration pattern and its per-tick bookkeeping.
///
/// Owned by `PageCanvasController`, one per live canvas, installed at
/// `viewDidLoad`. The pattern is a page-space grid with fiducial crosshairs:
/// ink drawn along a grid line must stay on that line through pinch, fling,
/// and rubber-band; any drift at the fiducials is misregistration and is the
/// spike's whole observable.
@MainActor
final class SpikeMirror {

    enum Variant: String {
        /// A sibling view *under* a transparent `PKCanvasView`, mirrored per
        /// scroll tick. The presumed winner.
        case sibling
        /// A subview inserted *inside* `PKCanvasView`, beneath the ink.
        /// Expected to reproduce the recorded `_delayTouchesForEvent:` crash
        /// on the first stroke — that crash is a valid spike result.
        case inside
    }

    let variant: Variant

    /// The layer carrying the pattern bitmap. Page-sized bounds, anchor at the
    /// page origin, positioned once at install; every tick assigns exactly one
    /// transform to it.
    private let patternLayer = CALayer()

    /// The view whose layer hosts `patternLayer`. For `.sibling` it sits below
    /// the canvas in `PageCanvasController.view`; for `.inside` it is inserted
    /// at subview index 0 of the canvas itself.
    private let patternHost = UIView()

    // MARK: - Tick statistics (plain scalars — nothing allocates per tick)

    /// A gap between consecutive mirror ticks longer than this, while a
    /// gesture or deceleration is running, means at least one whole 120 Hz
    /// frame (8.33 ms) passed with no mirror assignment — the mirror was late
    /// relative to the scroll callbacks. 12 ms leaves margin over one frame so
    /// an ordinary 120 Hz cadence never trips it.
    private static let lateGapThreshold: CFTimeInterval = 0.012

    private var isTracking = false
    private var windowStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var tickCount = 0
    private var lateTicks = 0
    private var maxGap: CFTimeInterval = 0
    private var maxAssign: CFTimeInterval = 0

    // MARK: - Install

    /// Installs the spike into a live canvas, or returns nil when the variant
    /// environment variable is present but unparseable (fail loud, not
    /// default — `Contract.md`, Invalid states fail loud).
    ///
    /// `canvasView` is typed as `UIScrollView` so this file needs no PencilKit
    /// import; the caller passes the one `PKCanvasView`.
    static func install(under canvasView: UIScrollView, in hostView: UIView) -> SpikeMirror? {
        let raw = ProcessInfo.processInfo.environment["TN_SPIKE_MIRROR_VARIANT"] ?? Variant.sibling.rawValue
        guard let variant = Variant(rawValue: raw) else {
            CanvasLog.event(
                .canvas,
                "SPIKE mirror REFUSED: TN_SPIKE_MIRROR_VARIANT=\(raw) is not "
                    + "'sibling' or 'inside'; installing nothing"
            )
            return nil
        }
        return SpikeMirror(variant: variant, canvasView: canvasView, hostView: hostView)
    }

    private init(variant: Variant, canvasView: UIScrollView, hostView: UIView) {
        self.variant = variant

        // The canvas must show the pattern through it in both variants: in A
        // the pattern is behind the canvas, in B it is beneath the ink inside
        // it. This transparency is the ">= 2x overdraw, said plainly" cost the
        // fork doc prices; the spike exists to feel it at 120 Hz.
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false

        // A distinct backdrop behind everything, so the page edge is visible
        // against not-page during rubber-band and overview zoom.
        hostView.backgroundColor = .systemGray4

        patternHost.isUserInteractionEnabled = false
        patternHost.translatesAutoresizingMaskIntoConstraints = true

        patternLayer.anchorPoint = .zero
        patternLayer.position = .zero
        patternLayer.bounds = CGRect(x: 0, y: 0, width: PageGeometry.width, height: PageGeometry.height)
        patternLayer.contents = Self.renderPattern().cgImage
        // Nearest-at-magnification would exaggerate softness; linear is what a
        // real composite texture would do. Softness under deep zoom is
        // expected and is NOT the observable — line *position* is.
        patternLayer.magnificationFilter = .linear
        patternHost.layer.addSublayer(patternLayer)

        switch variant {
        case .sibling:
            patternHost.frame = hostView.bounds
            patternHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            CanvasLog.event(
                .canvas,
                "SPIKE mirror installing variant=sibling: pattern view under a "
                    + "transparent PKCanvasView, mirrored per scroll tick"
            )
            hostView.insertSubview(patternHost, belowSubview: canvasView)

        case .inside:
            patternHost.frame = patternLayer.bounds
            // The log line the crash trace hangs off. If the app dies on the
            // first Pencil stroke after this line, that is the recorded
            // `_delayTouchesForEvent:` class reproducing, and it is the spike
            // answering question B with "no".
            CanvasLog.event(
                .canvas,
                "SPIKE mirror installing variant=inside: INSERTING SUBVIEW INTO "
                    + "PKCanvasView at index 0 — a first-stroke crash after this "
                    + "line is the recorded _delayTouchesForEvent: class"
            )
            canvasView.insertSubview(patternHost, at: 0)
            CanvasLog.event(.canvas, "SPIKE mirror variant=inside: insertion returned without crashing")
        }
    }

    // MARK: - The frame path

    /// One mirror assignment. Called from `scrollViewDidScroll`,
    /// `scrollViewDidZoom`, and layout — the canvas runtime's existing
    /// callbacks, nothing new observes the scroll view.
    ///
    /// Per tick this does: one `CACurrentMediaTime`, a few scalar compares, one
    /// `CATransform3D` construction on the stack, one layer property
    /// assignment inside a disabled-actions transaction, one more
    /// `CACurrentMediaTime`. No allocation, no logging, no publication.
    func mirror(offset: CGPoint, zoom: CGFloat) {
        let now = CACurrentMediaTime()
        if isTracking {
            let gap = now - lastTick
            if gap > Self.lateGapThreshold { lateTicks += 1 }
            if gap > maxGap { maxGap = gap }
        } else {
            isTracking = true
            windowStart = now
            tickCount = 0
            lateTicks = 0
            maxGap = 0
            maxAssign = 0
        }
        lastTick = now
        tickCount += 1

        // Page point p renders at:
        //   sibling: p * zoom - contentOffset   (view space of the host)
        //   inside:  p * zoom                   (content space; the scroll
        //            view's bounds origin moves subviews itself, exactly as it
        //            moves the pageBoundary layer)
        let transform: CATransform3D
        switch variant {
        case .sibling:
            transform = CATransform3DScale(
                CATransform3DMakeTranslation(-offset.x, -offset.y, 0), zoom, zoom, 1
            )
        case .inside:
            transform = CATransform3DMakeScale(zoom, zoom, 1)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patternLayer.transform = transform
        CATransaction.commit()

        let assignDuration = CACurrentMediaTime() - now
        if assignDuration > maxAssign { maxAssign = assignDuration }
    }

    /// Emits one summary line for the tick window that just ended, and closes
    /// the window. Called from the scroll view's end-of-gesture callbacks —
    /// once per fling, pinch, or drag, never per frame.
    func flushStats(_ label: String) {
        guard isTracking else { return }
        isTracking = false
        let elapsed = lastTick - windowStart
        let rate = elapsed > 0 ? Double(tickCount) / elapsed : 0
        CanvasLog.event(
            .canvas,
            String(
                format: "SPIKE mirror %@ variant=%@ ticks=%ld elapsed=%.3fs "
                    + "ticksPerSecond=%.1f lateTicks(>12ms gap)=%ld maxGapMs=%.2f "
                    + "maxAssignMs=%.3f",
                label, variant.rawValue, tickCount, elapsed, rate, lateTicks,
                maxGap * 1000, maxAssign * 1000
            )
        )
    }

    // MARK: - The registration pattern

    /// Rendered once, at install — construction is not an interaction path.
    ///
    /// Page-space content, high contrast, built so misregistration is visible
    /// to the eye rather than inferred:
    /// - a fine 20 pt grid and a heavier 100 pt grid: ink ruled along a line
    ///   must stay on it;
    /// - corner-to-corner diagonals: drift shows everywhere, not only near a
    ///   line;
    /// - red crosshair fiducials with page-space coordinate labels at the four
    ///   100 pt-inset corners and the page center: the spots to stare at
    ///   during pinch, fling, and rubber-band.
    private static func renderPattern() -> UIImage {
        let size = CGSize(width: PageGeometry.width, height: PageGeometry.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext

            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            func strokeGrid(step: CGFloat, color: UIColor, width: CGFloat) {
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                var x: CGFloat = 0
                while x <= size.width {
                    cg.move(to: CGPoint(x: x, y: 0))
                    cg.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= size.height {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                cg.strokePath()
            }

            strokeGrid(step: 20, color: UIColor(white: 0.85, alpha: 1), width: 0.5)
            strokeGrid(step: 100, color: UIColor(white: 0.55, alpha: 1), width: 1)

            // Diagonals.
            cg.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.6).cgColor)
            cg.setLineWidth(1)
            cg.move(to: .zero)
            cg.addLine(to: CGPoint(x: size.width, y: size.height))
            cg.move(to: CGPoint(x: size.width, y: 0))
            cg.addLine(to: CGPoint(x: 0, y: size.height))
            cg.strokePath()

            // Fiducials.
            let fiducials = [
                CGPoint(x: 100, y: 100),
                CGPoint(x: size.width - 100, y: 100),
                CGPoint(x: size.width / 2, y: size.height / 2),
                CGPoint(x: 100, y: size.height - 100),
                CGPoint(x: size.width - 100, y: size.height - 100),
            ]
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: UIColor.systemRed,
            ]
            cg.setStrokeColor(UIColor.systemRed.cgColor)
            cg.setLineWidth(1.5)
            for point in fiducials {
                cg.move(to: CGPoint(x: point.x - 14, y: point.y))
                cg.addLine(to: CGPoint(x: point.x + 14, y: point.y))
                cg.move(to: CGPoint(x: point.x, y: point.y - 14))
                cg.addLine(to: CGPoint(x: point.x, y: point.y + 14))
                cg.strokePath()
                cg.strokeEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                let label = "(\(Int(point.x)),\(Int(point.y)))" as NSString
                label.draw(at: CGPoint(x: point.x + 10, y: point.y + 10), withAttributes: labelAttributes)
            }
        }
    }
}

#endif

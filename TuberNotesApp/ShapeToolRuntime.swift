import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The shape tool's live half: it watches one Pencil drag, previews the shape
/// it would commit, and hands the finished strokes back on lift.
///
/// This is not a second owner. It is `PageCanvasController`'s own runtime,
/// split into a file of its own for size, constructed by that controller,
/// alive only inside it, and holding nothing durable. It is the same actor and
/// the same authority — the live canvas (`Contract.md` — Owners).
///
/// Nothing here leaves the canvas runtime. The preview is a `CAShapeLayer`
/// this object owns; no file is touched, nothing is published to SwiftUI, and
/// no drawing is mutated until the lift. Per frame of a drag the work is one
/// path build and one layer assignment, with implicit animation off — the same
/// shape of work `updatePageBoundary` already does per pinch frame.
@MainActor
final class ShapeToolRuntime: NSObject {
    /// Owned by `PageCanvasController`, which owns this object too; `unowned`
    /// because they are born and die together and a strong edge would only add
    /// a cycle to unpick.
    private unowned let canvasView: PKCanvasView

    /// The finished strokes, at the lift. The canvas controller performs the
    /// drawing mutation: this object never writes the live drawing, because the
    /// live drawing has one writer.
    var onCommit: (([PKStroke]) -> Void)?

    /// Which shape is being drawn, or `nil` for ordinary freehand ink.
    private(set) var kind: ShapeKind?

    /// The drag in progress, in **page points**.
    ///
    /// Page space rather than view or content coordinates, so that a pinch
    /// during the drag cannot strand the anchor: the page point the user
    /// started from is the same page point at any zoom
    /// (`Contract.md` — Geometry and coordinates).
    private var drag: (start: CGPoint, current: CGPoint)?

    /// The pen as it was when the drag began.
    ///
    /// Captured once rather than read per frame, so a shape is inked with the
    /// tool it was started with even if something changes the selection
    /// mid-drag.
    private var pen: PKInkingTool?

    /// The preview.
    ///
    /// A layer, not a view, and for exactly the reason `pageBoundary` is one:
    /// `PKCanvasView` is a `UIScrollView`, and a subview of it enters the
    /// scroll view's touch delay bookkeeping — which crashed UIKit inside
    /// `_delayTouchesForEvent:` on the first stroke. Layers never participate
    /// in touch handling.
    ///
    /// It is a sublayer of the canvas's own layer, so it pans with the page for
    /// free; only zoom needs it rebuilt, because content coordinates already
    /// include the zoom scale. `zPosition` lifts it above the ink PencilKit
    /// renders in a sibling layer, so the preview is not drawn under existing
    /// strokes.
    private let preview = CAShapeLayer()

    private let recognizer = PencilDragRecognizer()

    private var hasLoggedNonInkingTool = false

    init(canvasView: PKCanvasView) {
        self.canvasView = canvasView
        super.init()

        preview.fillColor = nil
        preview.lineCap = .round
        preview.lineJoin = .miter
        preview.zPosition = 1
        preview.isHidden = true
        canvasView.layer.addSublayer(preview)

        recognizer.addTarget(self, action: #selector(handleDrag))
        recognizer.isEnabled = false
        canvasView.addGestureRecognizer(recognizer)
    }

    // MARK: - Mode

    /// Switches the tool. `nil` restores ordinary freehand inking.
    ///
    /// The arbitration is one flag each way and no new claimant on the drag
    /// (`Contract.md` — Navigation): PencilKit's own inking is switched off
    /// exactly while ours is switched on, so a Pencil touch is claimed by
    /// exactly one of them at any moment. Finger behaviour is untouched —
    /// `PencilDragRecognizer` accepts no finger touch at all, so pan, pinch,
    /// and the page turn are the same gestures they were, arbitrated by the
    /// same scroll views.
    func setKind(_ kind: ShapeKind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        cancelDrag()
        recognizer.isEnabled = kind != nil
        canvasView.isDrawingEnabled = kind == nil
        CanvasLog.event(.canvas, "shape tool: \(kind?.rawValue ?? "off")")
    }

    /// The viewport changed under a drag in progress — rebuild the preview at
    /// the new scale. A no-op when nothing is being dragged, which is every
    /// zoom frame that is not also a shape drag.
    func viewportChanged() {
        guard drag != nil else { return }
        updatePreview()
    }

    // MARK: - The drag

    @objc
    private func handleDrag(_ recognizer: PencilDragRecognizer) {
        switch recognizer.state {
        case .began:
            guard let tool = canvasView.tool as? PKInkingTool else {
                // The eraser or the lasso is selected. Declining is the honest
                // answer: there is no ink to synthesize a shape from, and
                // inventing one would be picking a pen on the user's behalf.
                if !hasLoggedNonInkingTool {
                    hasLoggedNonInkingTool = true
                    CanvasLog.event(.canvas, "shape drag ignored: the selected tool does not ink")
                }
                recognizer.state = .cancelled
                return
            }
            pen = tool
            let point = pagePoint(recognizer.startLocation)
            drag = (start: point, current: point)
            updatePreview()

        case .changed:
            guard drag != nil else { return }
            drag?.current = pagePoint(recognizer.currentLocation)
            updatePreview()

        case .ended:
            guard let kind, let pen, let drag else {
                cancelDrag()
                return
            }
            let end = pagePoint(recognizer.currentLocation)
            cancelDrag()
            guard hypot(end.x - drag.start.x, end.y - drag.start.y) >= Self.minimumDragExtent else {
                // A tap, or a twitch. Committing a zero-sized rectangle would
                // leave an invisible stroke the user cannot see to erase.
                return
            }
            onCommit?(ShapeSynthesis.strokes(kind, from: drag.start, to: end, tool: pen))

        default:
            cancelDrag()
        }
    }

    /// How far the Pencil must travel before a drag is a shape, in page points.
    private static let minimumDragExtent: CGFloat = 4

    private func cancelDrag() {
        drag = nil
        pen = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.isHidden = true
        preview.path = nil
        CATransaction.commit()
    }

    /// Canvas content coordinates to page points.
    ///
    /// `location(in:)` on a scroll view already accounts for the content
    /// offset, and content coordinates are page points multiplied by the zoom
    /// scale — the same relation `updatePageBoundary` uses in the other
    /// direction. `contentSize` is not consulted: it is already multiplied by
    /// the zoom scale, and reading it as a page dimension is the classic way to
    /// corrupt page space into view space.
    private func pagePoint(_ contentPoint: CGPoint) -> CGPoint {
        let scale = canvasView.zoomScale
        guard scale > 0 else { return contentPoint }
        return CGPoint(x: contentPoint.x / scale, y: contentPoint.y / scale)
    }

    /// Rebuilds the preview path for the current drag.
    ///
    /// One `CGPath` per touch-move is the one allocation here and it is
    /// unavoidable: `CAShapeLayer.path` is an immutable path, so there is
    /// nothing to mutate in place. Nothing else allocates, nothing is
    /// published, and implicit animation is off — an animated path would lag
    /// the Pencil by the length of the default animation, which is precisely
    /// the feel this tool has to avoid.
    private func updatePreview() {
        guard let kind, let pen, let drag else { return }
        let scale = canvasView.zoomScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.strokeColor = pen.color.cgColor
        preview.lineWidth = pen.width * scale
        preview.path = Self.previewPath(
            kind,
            from: CGPoint(x: drag.start.x * scale, y: drag.start.y * scale),
            to: CGPoint(x: drag.current.x * scale, y: drag.current.y * scale)
        )
        preview.isHidden = false
        CATransaction.commit()
    }

    /// The preview shape, in canvas content coordinates.
    ///
    /// Deliberately *not* the synthesized strokes rendered: a preview is a
    /// hairline promise of where the ink will land, and building several
    /// hundred `PKStrokePoint`s per touch-move to draw it would be the
    /// per-sample allocation the performance rules forbid. The two agree
    /// because they are both the same ideal geometry — `ShapeSynthesis` samples
    /// it, this traces it.
    private static func previewPath(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint) -> CGPath {
        switch kind {
        case .line:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .rectangle:
            return CGPath(rect: ShapeSynthesis.normalized(from: start, to: end), transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: ShapeSynthesis.normalized(from: start, to: end), transform: nil)
        }
    }
}

/// A Pencil-only drag, recognized the instant the Pencil lands.
///
/// Two properties earn it its own class. It accepts **no finger touch at all**,
/// so with the shape tool active a finger still pans, pinches, and turns the
/// page exactly as before — the shape tool is a mode switch on the Pencil, not
/// a new claimant on every drag. And it recognizes on touch-down rather than
/// after a movement threshold, which is what stops the enclosing scroll views
/// from stealing the first few points of a shape: the first recognizer to
/// recognize prevents the others, and a pan cannot recognize before it has
/// moved.
@MainActor
final class PencilDragRecognizer: UIGestureRecognizer {
    /// Where the Pencil landed, in the view's coordinates.
    private(set) var startLocation: CGPoint = .zero

    /// Where it is now, in the view's coordinates.
    private(set) var currentLocation: CGPoint = .zero

    private var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, trackedTouch == nil, let touch = touches.first,
            touch.type == .pencil
        else {
            state = .failed
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view)
        currentLocation = startLocation
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        currentLocation = tracked.location(in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        currentLocation = tracked.location(in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}

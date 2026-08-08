// UIKit, because this is the canvas runtime: it owns two gesture recognizers
// on the live canvas and a `CAShapeLayer` of selection chrome, both of which
// are frame-frequency UIKit objects. It is `PageCanvasController`'s own
// runtime, split into a file of its own for size, exactly as
// `ShapeToolRuntime` and `PageBackdrop` are — not a second owner. PencilKit is
// deliberately *not* imported: nothing here needs a canvas's vocabulary, only a
// scroll view's zoom scale and a layer to hang chrome on.
import TuberModel
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Selection and the transform gesture for one page's `image` layers.
///
/// Phase 4 of `Docs/Forks/CanvasFeatureComplete.md`. Everything here is
/// frame-frequency state owned by the canvas runtime: a selection, a transform
/// in progress, and the chrome that draws them. **None of it is durable and
/// none of it is published.** At the end of a gesture this hands
/// `PageCanvasController` one committed `PageSpaceTransform`, which follows the
/// ordinary save path through `EditorSession` — the ink handover pattern
/// verbatim.
///
/// ## Arbitration: selection is the mode switch
///
/// `Contract.proposed.md` A11 and the fork doc's "The gesture problem, named as
/// what it is". Layer manipulation is a **third claimant** on a drag that
/// *Navigation* already settled for two, and the rule is:
///
/// - **With no selection, every touch behaves exactly as today.** This object
///   is not even constructed for a page with no selectable layer, so a blank
///   notebook grows no recognizer at all — the same "paid per page that has a
///   stack" narrowing `PageBackdrop` makes for transparency. On a page that
///   *does* carry an image, the cost is one `UITapGestureRecognizer`, which
///   cannot claim a drag: a tap needs a stationary touch and a scroll view's
///   pan needs a moving one, so they never contend.
/// - A tap on a selectable layer selects it; a tap elsewhere deselects.
/// - **While a selection exists**, a drag beginning on the selected layer (or
///   on one of its handles) is a transform, and `LayerDragRecognizer` claims it
///   on touch-down — the same trick `PencilDragRecognizer` uses, for the same
///   reason: the first recognizer to recognize prevents the others, and a pan
///   cannot recognize before it has moved.
/// - A drag beginning anywhere else **fails the recognizer in `touchesBegan`**,
///   so the two `UIScrollView`s see exactly the touch sequence they see today.
///   The turn at fit-width and the pan inside the page are untouched.
///
/// The fork doc's escape hatch — a selection *chrome view* owning its own
/// recognizers, arbitrating by hit-testing — was considered and **rejected**;
/// the reason is recorded at `LayerDragRecognizer`.
///
/// ## Why single-finger handles and no pinch
///
/// Scale and rotate are handle drags, not a pinch. A `UIPinchGestureRecognizer`
/// would contend directly with `PKCanvasView`'s own pinch-zoom — the one
/// gesture *Navigation* hands to the framework outright — and winning that
/// fight means either stealing zoom while an image is selected or losing the
/// scale. Handles need no arbitration at all: they are a different *place*, and
/// place is what the hit test already answers.
@MainActor
final class LayerSelectionRuntime: NSObject {
    /// The live canvas, as a scroll view. Owned by `PageCanvasController`,
    /// which owns this object too; `unowned` because they are born and die
    /// together.
    private unowned let canvasView: UIScrollView

    /// This page's extent, told at construction like everything else here.
    ///
    /// It exists for one rule: **a drag may not carry a layer off the page.**
    /// See `clampedToPage`.
    private let geometry: PageGeometry

    /// This page's layers below the ink, in order — bottom first, which is why
    /// hit-testing walks it backwards.
    private(set) var layers: [LayerEnvelope] = []

    private(set) var selectedLayerID: UUID?

    /// The selected layer's transform including any drag in progress. This is
    /// the frame-frequency value; the durable one is whatever `EditorSession`
    /// last committed.
    private(set) var liveTransform: PageSpaceTransform?

    /// The selection changed. `PageCanvasController` answers by asking for the
    /// lifted layer's own image and then for the minus-one composite.
    var onSelectionChanged: (() -> Void)?

    /// One frame of a transform in progress. Nothing durable, nothing
    /// published: the controller moves one `CALayer`.
    var onTransformPreview: ((PageSpaceTransform) -> Void)?

    /// The gesture ended on a transform that differs from where it began.
    /// Returns whether the commit was accepted — a refusal (a locked layer, a
    /// page that stopped taking input under the gesture) puts the layer back.
    var onTransformCommitted: ((UUID, PageSpaceTransform, PageSpaceTransform) -> Bool)?

    // MARK: - Chrome

    /// The selection outline and its handles.
    ///
    /// A layer, not a view, for the reason every decoration in this project is
    /// one: `PKCanvasView` is a `UIScrollView`, and a subview of it enters the
    /// scroll view's touch-delay bookkeeping, which crashed UIKit inside
    /// `_delayTouchesForEvent:` on the first Pencil stroke. It is a sublayer of
    /// the canvas's own layer, so it pans with the page for free; only zoom
    /// needs it rebuilt.
    ///
    /// `zPosition` puts it above the ink PencilKit renders and above the shape
    /// tool's preview, so chrome is never drawn under a stroke.
    private let chrome = CAShapeLayer()

    /// Touch slop for a handle, in **view** points — converted to page points
    /// through the zoom scale, so a handle is the same size under the finger at
    /// every zoom. Comfortably larger than the drawn handle, because a handle
    /// you must hit exactly is a handle you miss.
    private static let handleTouchRadius: Double = 22

    /// The drawn handle, in view points.
    private static let handleDrawRadius: Double = 5

    /// How far the rotation handle sits outside the top edge, in view points.
    private static let rotationHandleDistance: Double = 34

    private let tap = UITapGestureRecognizer()
    private let drag = LayerDragRecognizer()

    init(canvasView: UIScrollView, geometry: PageGeometry) {
        self.canvasView = canvasView
        self.geometry = geometry
        super.init()

        chrome.fillColor = nil
        chrome.strokeColor = UIColor.tintColor.cgColor
        chrome.lineJoin = .round
        chrome.zPosition = 2
        chrome.isHidden = true
        canvasView.layer.addSublayer(chrome)

        // Finger only. Pencil writes; `drawingPolicy = .pencilOnly` is the rule
        // this must not perturb, so neither recognizer accepts a Pencil touch
        // and inking is exactly what it was.
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.addTarget(self, action: #selector(handleTap))
        canvasView.addGestureRecognizer(tap)

        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        drag.shouldBegin = { [weak self] point in
            guard let self else { return false }
            return self.grab(atPagePoint: self.pagePoint(point)) != nil
        }
        drag.addTarget(self, action: #selector(handleDrag))
        // Nothing is selected yet, so there is nothing this could claim. It is
        // switched on and off with the selection, which is what makes
        // "with no selection, every touch behaves exactly as today" a fact
        // about the recognizer rather than a promise about its delegate.
        drag.isEnabled = false
        canvasView.addGestureRecognizer(drag)
    }

    /// Detaches everything this installed. Called when the page's last
    /// selectable layer goes away, and when the page retires.
    func remove() {
        clearSelection()
        canvasView.removeGestureRecognizer(tap)
        canvasView.removeGestureRecognizer(drag)
        chrome.removeFromSuperlayer()
    }

    // MARK: - The layer list

    /// Told, never asked (`Contract.md` — Owners, golden rule 7). The list
    /// belongs to `EditorSession`; this holds it only to hit-test against.
    ///
    /// A selection survives a list change that keeps its layer — which is
    /// exactly what a commit produces, because the session answers a commit by
    /// handing the page its new list. A selection whose layer left the list is
    /// dropped.
    func setLayers(_ layers: [LayerEnvelope]) {
        self.layers = layers
        guard let selectedLayerID else {
            updateChrome()
            return
        }
        guard let still = layers.first(where: { $0.layerID == selectedLayerID }) else {
            clearSelection()
            onSelectionChanged?()
            return
        }
        // Not during a drag: the gesture owns the value until it ends, and
        // adopting the durable one mid-gesture would snap the layer back to
        // wherever the last commit left it.
        //
        // Outside a drag the durable value is the authority, and adopting it is
        // what makes **undo visible**: an undo re-emits the prior transform
        // through the session, the session hands the page its new list, and
        // this is where the lifted layer and its chrome follow. Without it the
        // file would move and the picture would not.
        if activeDrag == nil, liveTransform != still.pageSpaceTransform {
            liveTransform = still.pageSpaceTransform
            onTransformPreview?(still.pageSpaceTransform)
        }
        updateChrome()
    }

    var selectedLayer: LayerEnvelope? {
        guard let selectedLayerID else { return nil }
        return layers.first { $0.layerID == selectedLayerID }
    }

    // MARK: - Selection

    /// The topmost selectable layer under a page point, if any. Later in the
    /// list is higher on the page, so the search runs backwards.
    func layer(atPagePoint point: CGPoint) -> LayerEnvelope? {
        layers.reversed().first { layer in
            layer.isSelectable
                && layer.pageSpaceTransform.containsUnitSquarePoint(
                    x: Double(point.x), y: Double(point.y)
                )
        }
    }

    /// A tap landed. Selects the topmost layer under it, or deselects.
    /// Returns whether the selection changed.
    @discardableResult
    func tapped(atPagePoint point: CGPoint) -> Bool {
        let hit = layer(atPagePoint: point)
        guard hit?.layerID != selectedLayerID else { return false }
        select(hit)
        return true
    }

    /// A locked layer is selected here exactly like any other: locked refuses
    /// *transforms*, not addressability (`Contract.proposed.md` A11).
    func select(_ layer: LayerEnvelope?) {
        guard let layer else {
            clearSelection()
            onSelectionChanged?()
            return
        }
        precondition(
            layer.isSelectable,
            "layer \(layer.layerID) is of kind \"\(layer.kind)\", which is not selectable"
        )
        selectedLayerID = layer.layerID
        liveTransform = layer.pageSpaceTransform
        drag.isEnabled = true
        updateChrome()
        onSelectionChanged?()
    }

    private func clearSelection() {
        selectedLayerID = nil
        liveTransform = nil
        activeDrag = nil
        drag.isEnabled = false
        updateChrome()
    }

    // MARK: - The transform gesture

    /// What a drag on the selection does. The mode is decided once, at
    /// touch-down, by *where* the touch landed — the hit test is the whole
    /// arbitration, which is why no recognizer delegate appears in this file.
    enum Grab: Equatable {
        case move
        /// Scale about the opposite corner. The index is the unit-square
        /// corner under the finger, in the order below.
        case scale(corner: Int)
        case rotate
    }

    /// The unit square's corners, in the order `scale(corner:)` indexes them.
    private static let unitCorners: [(x: Double, y: Double)] = [
        (0, 0), (1, 0), (1, 1), (0, 1),
    ]

    private struct ActiveDrag {
        let layerID: UUID
        let grab: Grab
        /// The transform as it was when the finger landed. **Every frame is
        /// computed from this**, never from the previous frame, so a long drag
        /// accumulates no floating-point drift and a reversal returns exactly.
        let startTransform: PageSpaceTransform
        let startPoint: CGPoint
        /// For a rotation: the angle from the layer's centre to the finger at
        /// touch-down, in page space.
        let startAngle: Double
    }

    private var activeDrag: ActiveDrag?

    /// What a touch at this page point would begin, or `nil` for "not mine" —
    /// which is the fall-through the whole arbitration rests on.
    func grab(atPagePoint point: CGPoint) -> Grab? {
        guard let layer = selectedLayer, let transform = liveTransform else { return nil }
        // Locked: selectable, not transformable. Returning `nil` means the drag
        // recognizer fails and the touch reaches the scroll views, so a locked
        // image pans and turns the page exactly like bare paper.
        guard layer.isTransformable else { return nil }

        let slop = Self.handleTouchRadius / zoomScale
        let x = Double(point.x)
        let y = Double(point.y)

        let rotationHandle = rotationHandlePosition(transform)
        if hypot(rotationHandle.x - x, rotationHandle.y - y) <= slop { return .rotate }

        for (index, corner) in Self.unitCorners.enumerated() {
            let placed = transform.apply(x: corner.x, y: corner.y)
            if hypot(placed.x - x, placed.y - y) <= slop { return .scale(corner: index) }
        }

        return transform.containsUnitSquarePoint(x: x, y: y) ? .move : nil
    }

    /// Begins a transform, or refuses. `false` means the caller must let the
    /// touch through untouched.
    @discardableResult
    func beginTransform(atPagePoint point: CGPoint) -> Bool {
        guard let layerID = selectedLayerID,
              let transform = liveTransform,
              let grab = grab(atPagePoint: point)
        else { return false }

        let centre = transform.apply(x: 0.5, y: 0.5)
        activeDrag = ActiveDrag(
            layerID: layerID,
            grab: grab,
            startTransform: transform,
            startPoint: point,
            startAngle: atan2(Double(point.y) - centre.y, Double(point.x) - centre.x)
        )
        return true
    }

    /// One frame of the drag.
    ///
    /// A candidate that is not invertible is **not applied** — the layer keeps
    /// the last good frame. That is not a clamped value: nothing durable is
    /// written here, and declining to show a collapsed layer is the gesture
    /// refusing to author an invalid state rather than correcting one
    /// (`Contract.md` — Invalid states fail loud, which forbids *saving* a
    /// singular transform, and this is how none is ever produced).
    func updateTransform(toPagePoint point: CGPoint) {
        guard let active = activeDrag else { return }
        guard let candidate = transform(for: active, at: point), candidate.isInvertible else {
            return
        }
        liveTransform = candidate
        onTransformPreview?(candidate)
        updateChrome()
    }

    /// The lift. One immutable committed value crosses the boundary here and
    /// nowhere else.
    func endTransform() {
        guard let active = activeDrag, let committed = liveTransform else { return }
        activeDrag = nil
        guard committed != active.startTransform else {
            // A tap that the drag recognizer claimed because it landed on the
            // selection. Nothing moved, so nothing is committed and nothing is
            // registered for undo.
            return
        }
        let accepted = onTransformCommitted?(active.layerID, active.startTransform, committed) ?? true
        guard !accepted else { return }
        // Refused. The durable value never changed, so the live one must not
        // either — anything else leaves the picture disagreeing with the file.
        liveTransform = active.startTransform
        onTransformPreview?(active.startTransform)
        updateChrome()
    }

    func cancelTransform() {
        guard let active = activeDrag else { return }
        activeDrag = nil
        liveTransform = active.startTransform
        onTransformPreview?(active.startTransform)
        updateChrome()
    }

    /// The candidate transform for one frame of a drag.
    private func transform(for active: ActiveDrag, at point: CGPoint) -> PageSpaceTransform? {
        let start = active.startTransform
        switch active.grab {
        case .move:
            // A translation in page space, applied after the layer's own
            // mapping: the layer keeps its size and orientation exactly.
            return clampedToPage(
                start.concatenating(
                    .translation(
                        x: Double(point.x - active.startPoint.x),
                        y: Double(point.y - active.startPoint.y)
                    )
                )
            )

        case .scale(let corner):
            // Uniform **in the layer's own frame**, which is what preserves the
            // placed aspect ratio: a source fitted to the page is anisotropic
            // in page space by construction (`PageSpaceTransform.fittingSource`
            // sets `a` and `d` independently), so a page-space uniform scale
            // would silently reshape it.
            //
            // The factor is a **page-space** distance ratio, finger-to-anchor
            // over corner-to-anchor. It must not be measured in unit space:
            // there the placed axes are compressed by 1/width and 1/height, so
            // unit distance is proportional to page distance only on a square
            // placement — on any other, the short axis outweighs the long one
            // and the grabbed corner leaves the finger. Page-space distance is
            // rotation-invariant, so a rotated placement measures the same.
            let anchor = Self.unitCorners[(corner + 2) % 4]
            let dragged = Self.unitCorners[corner]
            let placedAnchor = start.apply(x: anchor.x, y: anchor.y)
            let placedCorner = start.apply(x: dragged.x, y: dragged.y)
            let span = hypot(placedCorner.x - placedAnchor.x, placedCorner.y - placedAnchor.y)
            guard span > 0 else { return nil }
            let reach = hypot(Double(point.x) - placedAnchor.x, Double(point.y) - placedAnchor.y)
            let factor = reach / span
            guard factor.isFinite, factor > 0 else { return nil }
            let about = PageSpaceTransform
                .translation(x: -anchor.x, y: -anchor.y)
                .concatenating(.scale(factor))
                .concatenating(.translation(x: anchor.x, y: anchor.y))
            return about.concatenating(start)

        case .rotate:
            // About the layer's centre, **in page space** rather than in unit
            // space, for the same anisotropy reason: rotating the unit square
            // and then applying a non-uniform mapping is a shear, not a
            // rotation, and the handle would not track the finger.
            let centre = start.apply(x: 0.5, y: 0.5)
            let angle = atan2(Double(point.y) - centre.y, Double(point.x) - centre.x)
            let delta = angle - active.startAngle
            let about = PageSpaceTransform
                .translation(x: -centre.x, y: -centre.y)
                .concatenating(.rotation(delta))
                .concatenating(.translation(x: centre.x, y: centre.y))
            return start.concatenating(about)
        }
    }

    /// Slides a candidate back until the layer's centre is on the page.
    ///
    /// **A drag may not carry a layer off the page.** Phillip's device verdict
    /// (2026-08-07): an image dragged past the edge was *lost* — `PageBackdrop`
    /// masks to the page, so a layer entirely outside it draws nothing, and a
    /// layer that draws nothing cannot be tapped to select, so nothing can drag
    /// it back. It is still in the file and still in the composite request; it
    /// is simply unreachable. That is a durable state the user cannot undo by
    /// looking at the screen, which makes it worse than the misplacement it
    /// comes from.
    ///
    /// The rule is the **centre**, not the whole quad: containing the whole
    /// layer would forbid the ordinary bleed of a photo off the edge of a page,
    /// which is a real thing people want. A centre on the page guarantees a
    /// quadrant of the layer is drawn, so there is always something to tap.
    ///
    /// Applied to `.move` and nothing else, because `.move` is the only grab
    /// that *can* lose a layer: `.rotate` turns about the centre, which is
    /// therefore invariant, and `.scale` is anchored at the opposite corner,
    /// which is therefore invariant — a scaled layer keeps a corner wherever
    /// its corner was, so it stays as reachable as it was when the drag began.
    ///
    /// Clamping rather than refusing: a refused frame would stick the layer
    /// under a still-moving finger and read as a dropped drag. This slides
    /// along the edge instead, which is what a wall feels like.
    private func clampedToPage(_ candidate: PageSpaceTransform) -> PageSpaceTransform {
        let centre = candidate.apply(x: 0.5, y: 0.5)
        let x = min(max(centre.x, 0), geometry.width)
        let y = min(max(centre.y, 0), geometry.height)
        guard x != centre.x || y != centre.y else { return candidate }
        return candidate.concatenating(.translation(x: x - centre.x, y: y - centre.y))
    }

    // MARK: - Chrome drawing

    /// The viewport or the zoom changed — rebuild the chrome at the new scale.
    /// A no-op with nothing selected, which is every zoom frame on every page
    /// the user is merely reading.
    func viewportChanged() {
        guard selectedLayerID != nil else { return }
        updateChrome()
    }

    private var zoomScale: Double {
        let scale = Double(canvasView.zoomScale)
        return scale > 0 ? scale : 1
    }

    /// Where the rotation handle sits, in page points: outside the middle of
    /// the layer's own top edge, along that edge's outward normal, so it
    /// follows the layer through any rotation.
    private func rotationHandlePosition(_ transform: PageSpaceTransform) -> (x: Double, y: Double) {
        let topMiddle = transform.apply(x: 0.5, y: 0)
        // The image of unit-space "up" (0, -1) under the linear part.
        let up = (x: -transform.c, y: -transform.d)
        let length = hypot(up.x, up.y)
        guard length > 0 else { return topMiddle }
        let distance = Self.rotationHandleDistance / zoomScale
        return (
            x: topMiddle.x + up.x / length * distance,
            y: topMiddle.y + up.y / length * distance
        )
    }

    /// Rebuilds the outline and handles in **canvas content coordinates** —
    /// page points times the zoom scale, the same space `ShapeToolRuntime`
    /// draws its preview in.
    ///
    /// One `CGPath` build per frame of a drag, and nothing else: no allocation
    /// beyond the path, no publication, and implicit animation off, because an
    /// animated outline would lag the finger by the length of the default
    /// animation.
    private func updateChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let layer = selectedLayer, let transform = liveTransform else {
            chrome.isHidden = true
            chrome.path = nil
            return
        }

        let scale = zoomScale
        let path = CGMutablePath()
        let corners = Self.unitCorners.map { corner -> CGPoint in
            let placed = transform.apply(x: corner.x, y: corner.y)
            return CGPoint(x: placed.x * scale, y: placed.y * scale)
        }
        path.addLines(between: corners)
        path.closeSubpath()

        if layer.isTransformable {
            let radius = Self.handleDrawRadius
            for corner in corners {
                path.addEllipse(in: CGRect(
                    x: corner.x - radius, y: corner.y - radius,
                    width: radius * 2, height: radius * 2
                ))
            }
            let handle = rotationHandlePosition(transform)
            let handlePoint = CGPoint(x: handle.x * scale, y: handle.y * scale)
            let topMiddle = transform.apply(x: 0.5, y: 0)
            path.move(to: CGPoint(x: topMiddle.x * scale, y: topMiddle.y * scale))
            path.addLine(to: handlePoint)
            path.addEllipse(in: CGRect(
                x: handlePoint.x - radius, y: handlePoint.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }

        // Dashed for a locked layer, and it carries no handles at all: the
        // chrome says what the layer will and will not do before the user
        // drags it and finds out.
        chrome.lineDashPattern = layer.locked ? [6, 4] : nil
        chrome.lineWidth = 1.5
        chrome.path = path
        chrome.isHidden = false
    }

    // MARK: - Recognizer adapters

    /// Canvas content coordinates to page points. Identical arithmetic to
    /// `ShapeToolRuntime.pagePoint`, and identical reasoning: `location(in:)`
    /// on a scroll view already accounts for the content offset, and content
    /// coordinates are page points times the zoom scale. `contentSize` is never
    /// consulted — it is already multiplied by the zoom scale, and reading it
    /// as a page dimension is the classic way to corrupt page space into view
    /// space.
    private func pagePoint(_ contentPoint: CGPoint) -> CGPoint {
        CGPoint(x: contentPoint.x / canvasView.zoomScale, y: contentPoint.y / canvasView.zoomScale)
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        tapped(atPagePoint: pagePoint(recognizer.location(in: canvasView)))
    }

    @objc
    private func handleDrag(_ recognizer: LayerDragRecognizer) {
        switch recognizer.state {
        case .began:
            beginTransform(atPagePoint: pagePoint(recognizer.startLocation))
        case .changed:
            updateTransform(toPagePoint: pagePoint(recognizer.currentLocation))
        case .ended:
            updateTransform(toPagePoint: pagePoint(recognizer.currentLocation))
            endTransform()
        default:
            cancelTransform()
        }
    }

    // MARK: - Read only by tests

    // Debug-only, as every `…ForTesting` member is; the reasoning is at
    // `EditorSession.staticRendererForTesting`.
    #if DEBUG
    /// The chrome layer, so a test can assert that selection draws something
    /// and deselection draws nothing.
    var chromeLayerForTesting: CAShapeLayer { chrome }

    /// Whether the drag recognizer is switched on. The arbitration rule
    /// "with no selection, every touch behaves exactly as today" is exactly
    /// this flag, so a test asserts the flag rather than the promise.
    var dragRecognizerIsEnabledForTesting: Bool { drag.isEnabled }
    #endif
}

/// A finger drag that claims the touch on touch-down, and only where the
/// selection runtime says it may.
///
/// Two properties earn it its own class, and they are `PencilDragRecognizer`'s
/// two properties with the touch types swapped.
///
/// It **recognizes on touch-down**, which is what stops the enclosing scroll
/// views from stealing the first points of a transform: the first recognizer to
/// recognize prevents the others, and a pan cannot recognize before it has
/// moved. And it **fails immediately** when `shouldBegin` says no, which is the
/// fall-through *Navigation* requires — a failed recognizer is invisible to the
/// scroll views, so a drag that begins off the selection pans and turns exactly
/// as it does today.
///
/// **Why not the fork doc's chrome-view escape hatch.** That hatch — a
/// selection view owning its own recognizers, arbitrating by hit-testing —
/// cannot be built here without breaking something worse. A chrome view under
/// the transparent `PKCanvasView` receives no touches at all, because the
/// canvas is above it and takes them; a chrome view *above* the canvas receives
/// them and therefore eats every Pencil touch over the selected image, so you
/// could no longer draw on top of a picture you had selected. Arbitration by
/// hit test is still what happens here — `shouldBegin` runs the same unit-square
/// test a view's `hitTest` would — it simply runs inside a recognizer that
/// declines instead of inside a view that must exist somewhere in the z-order.
/// If this fights UIKit on device, the finding is that *neither* structure
/// works and the design needs revisiting, not that the hatch was skipped.
@MainActor
final class LayerDragRecognizer: UIGestureRecognizer {
    /// Answers whether a touch at this point in the view's coordinates begins a
    /// transform. Set by `LayerSelectionRuntime`; `nil` means never.
    var shouldBegin: ((CGPoint) -> Bool)?

    private(set) var startLocation: CGPoint = .zero
    private(set) var currentLocation: CGPoint = .zero

    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, trackedTouch == nil, let touch = touches.first,
              touch.type == .direct
        else {
            state = .failed
            return
        }
        let location = touch.location(in: view)
        guard shouldBegin?(location) == true else {
            // Not on the selection. Failing rather than merely not beginning is
            // the point: a failed recognizer stops delaying the touch, so the
            // scroll views see it unchanged.
            state = .failed
            return
        }
        trackedTouch = touch
        startLocation = location
        currentLocation = location
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

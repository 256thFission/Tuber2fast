import PencilKit
import UIKit

/// The live runtime for exactly one page.
///
/// Per `Docs/Contract.md` — Owners, this owner holds the live
/// `PKDrawing`, pan, zoom, gestures, and page projection. It never reads or
/// writes files and never chooses save policy.
///
/// It does not know its own page index, its neighbours, or how many pages exist
/// (`Contract.md` — Owners). `PagedCanvasController` places it and
/// `EditorSession` decides which page it shows; this type is told, and never
/// asks.
///
/// `PKCanvasView` is itself a `UIScrollView`, so pan and zoom within a page are
/// the framework's own — no gesture recognizers of ours, and no frame-frequency
/// work leaving this runtime.
@MainActor
final class PageCanvasController: UIViewController, PKCanvasViewDelegate {
    let canvasView = PKCanvasView()

    /// One coarse notification that the drawing changed. It carries no drawing,
    /// no sample, and no generation number (`Contract.md` — Saving).
    var onDrawingChanged: (() -> Void)?

    /// Shared across pages and owned by `PagedCanvasController`. One picker per
    /// page would mean the selected tool resetting every time you turn one.
    private let toolPicker: PKToolPicker

    /// The viewport size the current zoom range was computed for, or `nil`
    /// before the first layout. Keyed on the size rather than on a bool so that
    /// repeated layout passes at one size change nothing, while a genuine
    /// viewport change — rotation, Split View — re-fits. See
    /// `establishZoomIfNeeded`.
    private var zoomRangeBounds: CGSize?

    /// A hairline showing where the page ends.
    ///
    /// Presentation only: it is not ink, is never part of the drawing, and is
    /// not persisted. The page and the canvas background are both white, so
    /// without it the page boundary is invisible.
    ///
    /// A layer, not a view, and that is load-bearing. `PKCanvasView` is a
    /// `UIScrollView`, and a scroll view delays and re-delivers touches to its
    /// subviews. Adding a subview put this decoration into that bookkeeping and
    /// crashed UIKit inside `_delayTouchesForEvent:` on the first Pencil stroke.
    /// Layers never participate in touch handling, so they cannot perturb it.
    private let pageBoundary = CALayer()

    /// Whether the session has opened this canvas for user editing.
    ///
    /// `EditorSession` writes it, once, at the transition to its ready phase; the
    /// canvas only remembers it. It exists to enforce that a loaded drawing is
    /// installed strictly before editing begins — see `installDrawing`. It gates
    /// input in no other way, and no longer needs to: a canvas is only
    /// constructed at all once the session supplied its ink, so there is no
    /// canvas whose input would have to be refused. A page without its bytes is
    /// a placeholder in `PagedCanvasController`, not a canvas.
    private var isEditable = false
    private var hasLoggedFirstTouch = false
    private var hasLoggedFirstChange = false

    /// The shape tool's live half, built with the view. See `ShapeToolRuntime`:
    /// it is this controller's own runtime rather than a second owner, and it
    /// writes nothing — it hands finished strokes back to `commit(_:)`, which
    /// is the one writer of the live drawing.
    private var shapeTool: ShapeToolRuntime?

    /// The shape the tool would draw, remembered until the view exists.
    ///
    /// `PagedCanvasController` sets the tool on every canvas, including one
    /// built while the tool is already on, and a canvas is configured before
    /// anything guarantees its view has loaded.
    private var shapeKind: ShapeKind?

    #if TN_SPIKE_MIRROR
    /// THROWAWAY SPIKE — CanvasFeatureComplete device spike 1, "Mirror
    /// fidelity". Compiled only under TN_SPIKE_MIRROR; see
    /// `SpikeMirrorFidelity.swift` for what it measures and why. Every use in
    /// this file is gated the same way, so with the flag off this controller
    /// is unchanged.
    private var spikeMirror: SpikeMirror?
    #endif

    init(toolPicker: PKToolPicker) {
        self.toolPicker = toolPicker
        super.init(nibName: nil, bundle: nil)

        // Page space and change reporting are established before the view
        // loads. Wiring them in `viewDidLoad` would mean a canvas that has not
        // yet been displayed silently reports no changes — the document would
        // take edits it never saved.
        //
        // Assigned unzoomed, which is correct because `zoomScale` is still 1
        // here and `UIScrollView` scales `contentSize` itself whenever the scale
        // changes. Nothing writes `contentSize` again: the page geometry is
        // fixed, so this is the only assignment it ever needs.
        canvasView.contentSize = CGSize(width: PageGeometry.width, height: PageGeometry.height)
        canvasView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageCanvasController is created in code only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // The canvas is the page: its content coordinate system is page space,
        // so ink is authored in page points regardless of zoom or view size.
        // `contentSize` and the delegate are established in `init`.
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true

        // Finger navigates, Pencil writes.
        canvasView.drawingPolicy = .pencilOnly

        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.bouncesZoom = true

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A scroll view scrolls by moving its layer's bounds origin, so a
        // sublayer pans with the page for free. Only zoom changes need it
        // resized, because content coordinates already include the zoom scale.
        pageBoundary.borderColor = UIColor.separator.cgColor
        canvasView.layer.addSublayer(pageBoundary)
        updatePageBoundary()

        let shapes = ShapeToolRuntime(canvasView: canvasView)
        shapes.onCommit = { [weak self] strokes in
            self?.commit(strokes)
        }
        shapes.setKind(shapeKind)
        shapeTool = shapes

        toolPicker.addObserver(canvasView)

        #if TN_SPIKE_MIRROR
        // Installed after the canvas's own setup so the spike's transparency
        // override wins over the opaque-white assignment above.
        spikeMirror = SpikeMirror.install(under: canvasView, in: view)
        #endif
    }

    /// Traces the page rect in page space, scaled into content coordinates.
    ///
    /// This does not touch `contentSize`. `UIScrollView` rescales `contentSize`
    /// itself when `zoomScale` changes, so writing it from here — during a pinch,
    /// every frame — would fight the gesture rather than correct anything.
    ///
    /// Implicit layer animations are disabled: during a pinch this runs every
    /// frame, and an animated frame change would lag the ink it borders.
    private func updatePageBoundary() {
        let scale = canvasView.zoomScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageBoundary.borderWidth = 1 / max(traitCollection.displayScale, 1)
        pageBoundary.frame = CGRect(
            x: 0,
            y: 0,
            width: PageGeometry.width * scale,
            height: PageGeometry.height * scale
        )
        CATransaction.commit()
    }

    /// Takes keyboard focus so the shared tool picker shows for this page.
    /// Called by `PagedCanvasController` when this page becomes the visible one;
    /// a page that is merely prepared alongside it must not steal focus.
    func becomeActivePage() {
        canvasView.becomeFirstResponder()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        CanvasLog.event(
            .canvas,
            "appeared; firstResponder=\(canvasView.isFirstResponder) "
                + "policy=\(canvasView.drawingPolicy.rawValue) "
                + "contentSize=\(canvasView.contentSize) zoom=\(canvasView.zoomScale)"
        )
    }

    /// The first touch to reach the canvas, and nothing after it.
    ///
    /// This exists to answer one question the crash reports could not: whether
    /// the app survives long enough to see a touch at all. It is not a
    /// per-sample hook — it logs once and then never again.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !hasLoggedFirstTouch else { return }
        hasLoggedFirstTouch = true
        let types = touches.map { "\($0.type.rawValue)" }.joined(separator: ",")
        CanvasLog.event(.canvas, "first touch reached the canvas; types=[\(types)]")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        establishZoomIfNeeded()
        centerPageInViewport()
        #if TN_SPIKE_MIRROR
        // Establishes initial registration and re-registers after a viewport
        // change; not a frame-frequency path.
        spikeMirror?.mirror(offset: canvasView.contentOffset, zoom: canvasView.zoomScale)
        #endif
    }

    /// How far below a full page you may zoom out. Two full pages of overview.
    private static let overviewFactor = 0.5

    /// Establishes the zoom range for the current viewport, and re-establishes
    /// it when the viewport itself changes size.
    ///
    /// Two separate scales, and the distinction is the point
    /// (`Contract.md` — Geometry and coordinates): the opening scale fits the page *width*,
    /// which is the comfortable scale to write at, while the floor fits the
    /// whole page with room to spare.
    ///
    /// A repeated layout pass at one size does nothing, which is the invariant
    /// in `Contract.md` — Performance that rebuilding SwiftUI views rebuilds
    /// neither a canvas nor its undo manager: host-view updates must not reset
    /// the viewport. A rotation or a Split View resize is not a host-view
    /// update — it is a different viewport, and leaving the old range in place
    /// would strand the page at a scale that no longer fits the screen and a
    /// floor computed for a screen that no longer exists.
    ///
    /// The user's zoom survives that change rather than snapping back to fit:
    /// the scale is carried across as a ratio of fit-width, so a page examined
    /// at twice fit-width is still at twice fit-width after a rotation. On the
    /// first pass the ratio is 1, so opening at fit-width is the same code path.
    ///
    /// KNOWN DEFECT: zoom lives per page and dies with the controller. A page
    /// retired from the live window is released with no zoom saved, so turning
    /// back rebuilds it at fit-width, while pages still inside the window keep
    /// their scale — inconsistent by distance rather than uniformly wrong. The
    /// tool picker is shared across pages for exactly this reason; zoom is not.
    /// Whether zoom *should* be shared is a feel question, and Phillip's.
    private func establishZoomIfNeeded() {
        let bounds = canvasView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds != zoomRangeBounds else { return }

        let fitWidth = bounds.width / PageGeometry.width
        let fitPage = min(fitWidth, bounds.height / PageGeometry.height)
        guard fitWidth > 0, fitWidth.isFinite, fitPage > 0, fitPage.isFinite else {
            return
        }

        let previousFitWidth = zoomRangeBounds.map { $0.width / PageGeometry.width }
        let ratio = previousFitWidth.map { canvasView.zoomScale / $0 } ?? 1

        // Order matters: the range must admit the new scale before it is set,
        // or UIScrollView clamps it to the range still describing the old
        // viewport.
        canvasView.minimumZoomScale = fitPage * Self.overviewFactor
        canvasView.maximumZoomScale = fitWidth * 8
        canvasView.zoomScale = min(
            max(fitWidth * ratio, canvasView.minimumZoomScale),
            canvasView.maximumZoomScale
        )
        zoomRangeBounds = bounds
        updatePageBoundary()
    }

    /// Keeps the page centred once it is smaller than the viewport.
    ///
    /// Below fit-width — and vertically at most scales, since the page is taller
    /// than it is wide — the scaled page does not fill the canvas. Without this
    /// it pins to the top-left and the empty room all falls to one side.
    /// `contentInset` is the mechanism rather than a content transform, because
    /// it moves only where the scroll view may rest, leaving content
    /// coordinates — and therefore page space and the boundary layer — alone.
    private func centerPageInViewport() {
        let bounds = canvasView.bounds.size
        let content = canvasView.contentSize
        let horizontal = max(0, (bounds.width - content.width) / 2)
        let vertical = max(0, (bounds.height - content.height) / 2)
        let inset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal
        )
        guard canvasView.contentInset != inset else { return }
        canvasView.contentInset = inset
    }

    // MARK: - The shape tool

    /// Selects the shape a Pencil drag commits, or `nil` for freehand ink.
    ///
    /// The active tool belongs to `PagedCanvasController` (`Contract.md` —
    /// Owners), which is why this is told and never asked: every live page and
    /// every page built afterwards carries the same setting, so the tool
    /// survives a page turn exactly as the pen does.
    func setShapeTool(_ kind: ShapeKind?) {
        shapeKind = kind
        shapeTool?.setKind(kind)
    }

    /// Commits synthesized strokes into the live drawing.
    ///
    /// One assignment, not four appends, and that is the whole undo story: a
    /// rectangle's four strokes land in a single drawing mutation inside a
    /// single undo group, so one Cmd-Z removes the rectangle rather than one
    /// side of it.
    ///
    /// The undo action is registered **before** the mutation, deliberately.
    /// PencilKit may or may not register an undo of its own for a programmatic
    /// `drawing` assignment — its documentation does not say, and the simulator
    /// cannot answer it because `undoManager` walks the responder chain. Both
    /// answers are safe here. Registering first means our restore is the
    /// *older* entry, so if PencilKit did register one its own undo runs first
    /// and against the state it recorded; ours then assigns the same drawing
    /// again, which is a no-op in content. And whether one action or two, the
    /// explicit group makes it exactly one undo step.
    ///
    /// It is not an interception and not a second manager (`Contract.md` —
    /// Undo): it is the same live undo manager, reached the same way, invoked
    /// exactly once per commit, and the resulting change follows the ordinary
    /// save path because it is an ordinary drawing change.
    func commit(_ strokes: [PKStroke]) {
        precondition(
            isEditable,
            "a shape cannot be committed into a canvas the session has not opened for editing"
        )
        guard !strokes.isEmpty else { return }

        let previous = canvasView.drawing
        var updated = previous
        updated.strokes.append(contentsOf: strokes)

        guard let undoManager = canvasView.undoManager else {
            // No manager in the responder chain — the canvas is unhosted, which
            // in practice means a test. The commit still happens; it is simply
            // not undoable, and nothing here fabricates a manager to hold an
            // action nobody can reach.
            canvasView.drawing = updated
            CanvasLog.event(.canvas, "committed \(strokes.count) shape stroke(s); no undo manager")
            return
        }

        undoManager.beginUndoGrouping()
        registerRestore(of: previous, with: undoManager)
        canvasView.drawing = updated
        undoManager.endUndoGrouping()

        CanvasLog.event(
            .canvas,
            "committed \(strokes.count) shape stroke(s); strokes=\(canvasView.drawing.strokes.count)"
        )
    }

    /// Registers one undo that restores `drawing`, and re-registers itself as
    /// the redo when it runs. Recursion is how a value-restoring undo stays
    /// undoable and redoable indefinitely without holding a stack of its own.
    private func registerRestore(of drawing: PKDrawing, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { controller in
            // The handler is not actor-isolated, and undo is invoked from the
            // main thread by the responder chain that reached it. Asserting
            // that loudly is better than hopping and losing the ordering.
            MainActor.assumeIsolated {
                controller.registerRestore(of: controller.canvasView.drawing, with: undoManager)
                controller.canvasView.drawing = drawing
            }
        }
    }

    /// Called by `PagedCanvasController` immediately before this page leaves
    /// the live window, after its ink has been handed over.
    ///
    /// `UndoManager` does not retain an action's target, so an action left
    /// behind by a retired page points at a released controller. The manager
    /// itself belongs to the responder chain and outlives the page, so the
    /// actions have to go with the page.
    ///
    /// KNOWN DEFECT: this drops the undo history for shapes committed on a page
    /// that then left the live window — turn away and back, and the shape is
    /// still there but no longer undoable. What PencilKit does with its own
    /// stroke actions in the same situation is unverified, so whether this is
    /// consistent with freehand ink or worse than it is unknown; both are
    /// device evidence. Undo across a page turn is not a property this project
    /// has ever claimed (`Contract.md` — Navigation: turning is not undoable),
    /// and a dangling target is a crash, so the safe half is taken here.
    func willRetire() {
        canvasView.undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Drawing transfer

    /// Takes an independent drawing snapshot for later serialization.
    ///
    /// Copying the live drawing is the only work performed on the main actor.
    /// The full `dataRepresentation()` traversal runs from the snapshot's
    /// utility task, after the debounce, never from PencilKit's callback.
    func drawingSnapshot() -> DrawingSnapshot {
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = DrawingSnapshot(drawing: canvasView.drawing)
        CanvasLog.event(
            .save,
            "copied drawing snapshot; strokes=\(canvasView.drawing.strokes.count) "
                + "duration=\(started.duration(to: clock.now))"
        )
        return snapshot
    }

    /// Opens the canvas for user editing. Called once by `EditorSession` when the
    /// document is loaded and the ready phase begins (`Contract.md` — Lifecycle).
    func markEditable() {
        isEditable = true
    }

    /// Installs a page's drawing, strictly before the canvas becomes editable.
    ///
    /// PencilKit reports this assignment as a drawing change — measured, and
    /// synchronously, see `PageCanvasControllerTests`. That callback must not
    /// mark the document dirty, and exactly one mechanism prevents it: the
    /// wiring order in `PagedCanvasController.makeCanvas`, which attaches the
    /// change callback only after this runs. There used to be a
    /// second, a flag raised and lowered around this assignment; it is gone
    /// because two mechanisms for one rule means neither is understood, and it
    /// would have been silently inert had delivery ever become asynchronous.
    ///
    /// That leaves the ordering itself as the load-bearing invariant, so it is
    /// enforced rather than described: installing over a canvas the user can
    /// already draw on would overwrite live ink with an older load result, which
    /// `Contract.md` — Lifecycle forbids outright. Nothing here decodes and
    /// nothing can throw — decoding saved bytes is the paging runtime's step,
    /// and bytes that refuse to decode never reach a canvas at all.
    func installDrawing(from snapshot: DrawingSnapshot) {
        precondition(
            !isEditable,
            "installDrawing must not run once the canvas is editable; "
                + "it would overwrite live ink with an older drawing"
        )
        canvasView.drawing = snapshot.drawingValue
    }

    // MARK: - PKCanvasViewDelegate

    /// Reported for every drawing mutation, including the load-time install. The
    /// canvas does not classify them: `EditorSession` owns save policy and is the
    /// one place that decides a change is not user editing.
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !hasLoggedFirstChange {
            hasLoggedFirstChange = true
            CanvasLog.event(
                .canvas,
                "first drawing change; strokes=\(canvasView.drawing.strokes.count)"
            )
        }
        onDrawingChanged?()
    }

    /// Frame-frequency work, and it stays here inside the canvas runtime: a
    /// frame assignment on one view, no publication and no allocation.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updatePageBoundary()
        centerPageInViewport()
        // Re-traces a shape preview at the new scale, and returns immediately
        // when no shape is being dragged — which is every zoom that is not also
        // a Pencil drag.
        shapeTool?.viewportChanged()
        #if TN_SPIKE_MIRROR
        // After centering, so the mirror reads the settled offset for this
        // tick. One transform assignment; see SpikeMirror.mirror.
        spikeMirror?.mirror(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)
        #endif
    }

    #if TN_SPIKE_MIRROR
    // THROWAWAY SPIKE hooks — the mirror tick on every scroll callback, and
    // one stats line at each gesture end. Nothing below exists with the flag
    // off; `PagedCanvasController` is the delegate of the *outer* paging
    // scroll view, so these observe only this page's own canvas.

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        spikeMirror?.mirror(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        spikeMirror?.flushStats("fling settled;")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { spikeMirror?.flushStats("drag ended at rest;") }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        spikeMirror?.flushStats("pinch ended;")
    }
    #endif
}

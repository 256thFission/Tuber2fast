import PencilKit
import SwiftUI
import UIKit

/// A copied, immutable snapshot of a PencilKit drawing.
///
/// In the iOS 26 SDK, `PKDrawing` is a `Sendable` value. Reading the canvas
/// property takes a value snapshot on the main actor; the value can then cross
/// to a utility task with compiler-checked transfer safety. The long-term page
/// store still replaces whole-drawing serialization with a measured,
/// page-bounded persistence boundary.
struct DrawingSnapshot: Sendable {
    private let drawing: PKDrawing

    @MainActor
    init(drawing: PKDrawing) {
        self.drawing = drawing
    }

    /// Serializes off the main actor and reports how long it took.
    ///
    /// The duration is returned rather than only logged because `EditorSession`
    /// derives the autosave debounce from it (`DataContract.md` §5): the cost of
    /// a whole-drawing serialization is only knowable here, and measuring it a
    /// second time on the session side would mean serializing twice.
    func serialized() async -> (data: Data, duration: Duration) {
        await Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            let started = clock.now
            let data = drawing.dataRepresentation()
            let duration = started.duration(to: clock.now)
            // `Thread.isMainThread` is unavailable from an async context, and
            // the point of this field is to prove that this work is off main —
            // so it is read from a synchronous closure, which is a legal
            // context for it. Dropping the field would drop the evidence.
            let onMainThread = { Thread.isMainThread }()
            CanvasLog.event(
                CanvasLog.save, "save",
                "serialized drawing snapshot; bytes=\(data.count) "
                    + "duration=\(duration) "
                    + "mainThread=\(onMainThread)"
            )
            return (data, duration)
        }.value
    }
}

/// The sole owner of the live canvas runtime.
///
/// Per `Docs/Architecture/DataContract.md` §2 this owner holds the live
/// `PKDrawing`, pan, zoom, gestures, and page projection. It is the only file
/// in the app that imports PencilKit or UIKit, it never reads or writes files,
/// and it never chooses save policy.
///
/// `PKCanvasView` is itself a `UIScrollView`, so pan and zoom are the framework's
/// own — no second scroll view, no gesture recognizers of ours, and no
/// frame-frequency work leaving this runtime.
@MainActor
final class PageCanvasController: UIViewController, PKCanvasViewDelegate {
    let canvasView = PKCanvasView()

    /// One coarse notification that the drawing changed. It carries no drawing,
    /// no sample, and no generation number (`DataContract.md` §5).
    var onDrawingChanged: (() -> Void)?

    /// The current page height. `EditorSession` owns this value; the canvas
    /// renders what it is told and never chooses it (`DataContract.md` §2 rule 7).
    private(set) var pageHeight: Double = PageGeometry.initialHeight

    private let toolPicker = PKToolPicker()
    private var hasEstablishedInitialZoom = false

    /// A hairline showing where the page ends.
    ///
    /// Presentation only: it is not ink, is never part of the drawing, and is
    /// not persisted. The page and the canvas background are both white, so
    /// without it the page boundary is invisible — which matters more once the
    /// page can grow.
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
    /// installed strictly before editing begins — see `installDrawing`.
    private var isEditable = false
    private var hasLoggedFirstTouch = false
    private var hasLoggedFirstChange = false

    init() {
        super.init(nibName: nil, bundle: nil)

        // Page space and change reporting are established before the view
        // loads. Wiring them in `viewDidLoad` would mean a canvas that has not
        // yet been displayed silently reports no changes — the document would
        // take edits it never saved.
        //
        // Assigned unzoomed, and that is correct rather than inconsistent with
        // `setPageHeight`: `zoomScale` is still 1 here, and `UIScrollView` scales
        // `contentSize` itself whenever the scale changes. Callers after the
        // opening zoom is established must therefore write the already-scaled
        // size, which is what `setPageHeight` does.
        canvasView.contentSize = CGSize(width: PageGeometry.width, height: pageHeight)
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

        toolPicker.addObserver(canvasView)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
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
            height: pageHeight * scale
        )
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The tool picker only shows for the first responder.
        canvasView.becomeFirstResponder()
        CanvasLog.event(
            CanvasLog.canvas, "canvas",
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
        CanvasLog.event(CanvasLog.canvas, "canvas", "first touch reached the canvas; types=[\(types)]")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        establishInitialZoomIfNeeded()
    }

    /// How far below a full page you may zoom out. Two full pages of overview.
    private static let overviewFactor = 0.5

    /// Establishes the viewport once. Later layout passes must not reset it
    /// (`Docs/Milestones/JustACanvas.md`, spatial behavior gates).
    ///
    /// Three separate scales, and the distinction is the whole point
    /// (`DataContract.md` §7):
    ///
    /// - the opening scale fits the page *width*, which is the comfortable
    ///   scale to write at;
    /// - the floor is derived from the *initial* page height, so the whole page
    ///   still fits on screen with room to spare; and
    /// - neither is derived from the *current* height, which is what keeps the
    ///   viewport stable as the page grows. A floor tied to the current height
    ///   would zoom the canvas further out with every extension.
    private func establishInitialZoomIfNeeded() {
        guard !hasEstablishedInitialZoom else { return }
        let bounds = canvasView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        let fitWidth = bounds.width / PageGeometry.width
        let fitInitialPage = min(fitWidth, bounds.height / PageGeometry.initialHeight)
        guard fitWidth > 0, fitWidth.isFinite, fitInitialPage > 0, fitInitialPage.isFinite else {
            return
        }

        canvasView.minimumZoomScale = fitInitialPage * Self.overviewFactor
        canvasView.maximumZoomScale = fitWidth * 8
        canvasView.zoomScale = fitWidth
        hasEstablishedInitialZoom = true
        updatePageBoundary()
    }

    // MARK: - Page height

    /// Renders a new page height. The page gains addressable area at the bottom
    /// and nothing else changes: ink keeps its page coordinates, and zoom and
    /// content offset are untouched (`DataContract.md` §5a).
    ///
    /// The zoom floor is not recomputed, because it depends on width alone.
    func setPageHeight(_ height: Double) {
        precondition(
            PageGeometry.isValidHeight(height),
            "PageCanvasController received unreachable page geometry"
        )
        pageHeight = height
        // Already-scaled, because `zoomScale` is no longer 1 by the time a page
        // can be extended. See the note in `init`.
        canvasView.contentSize = CGSize(
            width: PageGeometry.width * canvasView.zoomScale,
            height: height * canvasView.zoomScale
        )
        updatePageBoundary()
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
            CanvasLog.save, "save",
            "copied drawing snapshot; strokes=\(canvasView.drawing.strokes.count) "
                + "duration=\(started.duration(to: clock.now))"
        )
        return snapshot
    }

    /// Opens the canvas for user editing. Called once by `EditorSession` when the
    /// document is loaded and the ready phase begins (`DataContract.md` §6).
    func markEditable() {
        isEditable = true
    }

    /// Installs a loaded drawing, strictly before the canvas becomes editable.
    ///
    /// PencilKit reports this assignment as a drawing change — measured, and
    /// synchronously, see `PageCanvasControllerTests`. That callback must not
    /// mark the document dirty, and exactly one mechanism prevents it: the
    /// session ignores drawing changes until its ready phase. There used to be a
    /// second, a flag raised and lowered around this assignment; it is gone
    /// because two mechanisms for one rule means neither is understood, and it
    /// would have been silently inert had delivery ever become asynchronous.
    ///
    /// That leaves the ordering itself as the load-bearing invariant, so it is
    /// enforced rather than described: installing over a canvas the user can
    /// already draw on would overwrite live ink with an older load result, which
    /// `DataContract.md` §6 forbids outright.
    func installDrawing(from data: Data) throws {
        precondition(
            !isEditable,
            "installDrawing must not run once the canvas is editable; "
                + "it would overwrite live ink with a loaded drawing"
        )
        canvasView.drawing = try PKDrawing(data: data)
    }

    // MARK: - PKCanvasViewDelegate

    /// Reported for every drawing mutation, including the load-time install. The
    /// canvas does not classify them: `EditorSession` owns save policy and is the
    /// one place that decides a change is not user editing.
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !hasLoggedFirstChange {
            hasLoggedFirstChange = true
            CanvasLog.event(
                CanvasLog.canvas, "canvas",
                "first drawing change; strokes=\(canvasView.drawing.strokes.count)"
            )
        }
        onDrawingChanged?()
    }

    /// Frame-frequency work, and it stays here inside the canvas runtime: a
    /// frame assignment on one view, no publication and no allocation.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updatePageBoundary()
    }
}

/// Hosts the canvas runtime in SwiftUI.
///
/// The controller is owned by `EditorSession` and merely handed here, so
/// re-evaluating the SwiftUI body cannot rebuild the canvas or its undo manager
/// (`DataContract.md` §2 rule 6).
///
/// `updateUIViewController` is deliberately empty: intentions travel to the
/// session, which drives the canvas directly. Nothing about the canvas is
/// re-derived from SwiftUI state.
struct PageCanvas: UIViewControllerRepresentable {
    let controller: PageCanvasController

    func makeUIViewController(context: Context) -> PageCanvasController {
        return controller
    }

    func updateUIViewController(_ controller: PageCanvasController, context: Context) {}
}

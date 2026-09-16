import CoreGraphics
import PencilKit
import TNCore
import TNModel
import UIKit

/// What a page canvas reports to. Implemented by `PagedCanvasController`, which
/// is the one place that names the seam's reporter: a page controller is told
/// which page it is and reports to whoever placed it, and it never learns its
/// own index, its neighbours, or how many pages exist.
@MainActor
protocol PageCanvasOwner: AnyObject {
    func pageDidChangeInk(_ page: PageID, _ ink: PKDrawing, echoOf: InkSeq?)
    func pageDidRetire(_ page: PageID, finalInk: PKDrawing)
    func pageStrokeDidEnd(_ page: PageID)
    func pageDidActivateLink(_ page: PageID, layer: LayerID)
    /// The selection frame's drag ended. Answered synchronously, and the one
    /// report a drag makes.
    func pageDidTransformLayer(_ page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome
    /// Delete, from the selected object's menu. Answered by the composite
    /// that omits the layer.
    func pageDidRequestLayerDelete(_ page: PageID, layer: LayerID)
    /// Lock or Unlock, from the same menu. Answered by the composite whose
    /// layer list carries the flag.
    func pageDidRequestLayerLock(_ page: PageID, layer: LayerID, locked: Bool)
    func pageDidRequestTextBox(_ page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment)
    func pageDidRequestTextEdit(_ page: PageID, layer: LayerID)
    func pageDidEndTextEditing(_ page: PageID, layer: LayerID, _ text: TextLayer)
    /// The outer page-turn pan, which a border drag must not start.
    func pagingPanGestureRecognizer() -> UIGestureRecognizer?
}

/// The one overlay a page canvas may have up, structurally: a text session
/// needs the text tool and a selection needs the lasso, and `apply(tool:)`
/// ends whichever is open before the other can be asked for. The draft or
/// the placement is the canvas's until it ends, the way a stroke in flight
/// is PencilKit's.
enum OverlayPhase {
    case idle
    /// Reported a text request; no view yet. The overlay goes up when the
    /// omitting composite lands. A create request has no layer id until the
    /// notebook answers, so the case names none.
    case opening
    /// The text overlay is up and first responder.
    case editing(layer: LayerID, view: TextEditingView)
    /// An object is selected and its frame is up.
    case selected(layer: LayerID, view: LayerSelectionView)
}

/// Every layer of the installed snapshot, in stack order, each as the
/// transform that places its unit square.
///
/// Not a rect: a rotated image has no axis-aligned one, and a link's or a
/// text box's rect is `unitSquare(to:)`, so one shape answers for all four
/// kinds.
struct HitTarget: Equatable {
    let id: LayerID
    let kind: LayerKind
    let transform: PageSpaceTransform
    /// A locked target is still hit: the lasso raises a frame with no
    /// handles and an Unlock action, which is the only way back.
    let locked: Bool
}

/// What a tap with the text tool means.
enum TextTap: Equatable {
    case edit(LayerID)
    case create(PagePoint)
}

/// The live runtime for exactly one page.
///
/// It holds the working copy of the ink, the pan, and the zoom, and it is the
/// only construction site for `PKCanvasView` in the whole repository — one
/// site, not a singleton, because a second tab must be able to own independent
/// live canvases.
///
/// `PKCanvasView` is itself a `UIScrollView`, so pan and zoom inside a page are
/// the framework's own: its content coordinate system is page space, ink is
/// authored in page points at any zoom, and no gesture recognizer of ours is
/// involved in navigation.
@MainActor
package final class PageCanvasController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    package let pageID: PageID

    /// The ink surface. Content coordinates are page points.
    let canvasView = PKCanvasView()

    /// Paper and every static layer, as pixels, beneath the ink.
    private let backdropView = UIImageView()

    /// The page, mirrored either side of the ink. Both are page-sized views in
    /// page points, scaled and placed to sit exactly under the canvas's
    /// content on every scroll and zoom tick; `paperView` holds the backdrop
    /// beneath the ink and `overlayView` holds the text box and the selection
    /// frame above it. A subview placed in `canvasView` itself does not move
    /// with the ink: PencilKit zooms a private content view and paints its
    /// tiles opaquely over anything else, which an iPad Air showed on
    /// 2026-09-14 as a white page-sized strip beside a page that was not
    /// there. The per-tick placement is the price, and it is two frames.
    let paperView = PageMirrorView()
    let overlayView = PageMirrorView()

    private var geometry: PageGeometry
    private unowned let owner: any PageCanvasOwner

    /// Every layer of the installed snapshot, in stack order. A tap that
    /// lands inside one is an intention, reported and never acted on here.
    private(set) var hitTargets: [HitTarget] = []

    private var tool: CanvasTool?
    private(set) var phase: OverlayPhase = .idle
    /// Overlays whose end was reported and whose composite has not landed.
    /// Inert. A side map, not a phase: closing A and editing B happen in one
    /// tap.
    private(set) var closing: [LayerID: TextEditingView] = [:]
    /// How much of the viewport the software keyboard covers.
    private var keyboardOverlap: CGFloat = 0
    private var keyboardObservers: [any NSObjectProtocol] = []

    /// Set at `canvasViewDidBeginUsingTool`, cleared after the drawing change
    /// that follows `canvasViewDidEndUsingTool`. Installs, window changes, and
    /// teardown wait for it: the stroke under the Pencil right now is the one
    /// piece of ink no report can carry until it commits.
    private(set) var isStrokeInFlight = false

    /// The sequence of the ink this canvas last took from the notebook, at
    /// build or restore. The owner reads it against the snapshot's to find a
    /// restore a stroke deferred.
    private(set) var inkSeq: InkSeq?

    /// The tool use ended and its drawing change has not arrived yet.
    private var awaitingChangeAfterToolUse = false

    /// The sequence number of an install whose PencilKit callback has not
    /// arrived. The next drawing change carries it as `echoOf:` and the latch
    /// clears; if no callback comes, it clears at the end of the turn, so a set
    /// that fires nothing cannot arm it forever.
    private var pendingEcho: InkSeq?

    /// The final report was delivered. `deinit` traps if it is false: a page
    /// controller released without one is ink nobody has custody of.
    private var hasRetired = false

    /// The bounds the zoom range was established for. A viewport change
    /// re-establishes it; a scroll does not.
    private var zoomRangeBounds: CGSize?

    private let filteringUndoManager: FilteringUndoManager

    init(
        pageID: PageID,
        geometry: PageGeometry,
        ink: PKDrawing,
        inkSeq: InkSeq?,
        composite: Composite?,
        layers: [Layer],
        tool: CanvasTool?,
        canUndo: Bool,
        canRedo: Bool,
        owner: any PageCanvasOwner,
        reporter: any CanvasReporting
    ) {
        self.pageID = pageID
        self.geometry = geometry
        self.owner = owner
        self.inkSeq = inkSeq
        // The one report this controller does not route through its owner: the
        // undo manager is handed to the responder chain and answers UIKit
        // directly, so it carries the reporter rather than a hop through here.
        self.filteringUndoManager = FilteringUndoManager(reporter: reporter)
        super.init(nibName: nil, bundle: nil)
        filteringUndoManager.setAvailability(canUndo: canUndo, canRedo: canRedo)

        // Page space is established before the view loads, and before the
        // delegate is: a canvas that has not been displayed yet must already
        // measure in page points, and the install below must not be reported as
        // an edit.
        //
        // Assigned unzoomed, which is correct because `zoomScale` is still 1
        // here and `UIScrollView` scales `contentSize` itself whenever the
        // scale changes.
        canvasView.contentSize = CGSize(width: geometry.width, height: geometry.height)
        canvasView.drawing = ink
        canvasView.delegate = self
        // Belt and braces on the install above: if a build of PencilKit
        // delivers the change for a `drawing` assignment in a later turn, after
        // the delegate is attached, it arrives stamped as this content's echo
        // and the notebook drops it rather than taking it for an edit.
        //
        // Measured (simulator, iOS 26, `TNCanvasTests`): the callback for a
        // programmatic `drawing` assignment is synchronous and single. That is
        // what the latch below rests on, and it is the question the fork doc
        // left to this stage. It is not yet confirmed on a device.
        pendingEcho = inkSeq
        clearEchoLatchAtEndOfTurn(inkSeq)

        setLayers(layers)
        // The drawing gesture is PencilKit's and exists once the view loads;
        // the tool is applied there.
        self.tool = tool
        if let composite { backdropView.image = UIImage(cgImage: composite.image) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageCanvasController is created in code only")
    }

    deinit {
        // The one check that catches a dropped controller. A leaked one is
        // caught by the notebook, which asserts that every retire it asked for
        // has reported.
        if !hasRetired {
            TNPrecondition.fail("page \(pageID) was released without delivering its final ink report")
        }
    }

    /// The undo manager the responder chain finds from the canvas view.
    package override var undoManager: UndoManager? { filteringUndoManager }

    package override func viewDidLoad() {
        super.viewDidLoad()


        // Finger navigates, Pencil writes. The simulator has no Pencil, so a
        // hosted test would have no way to author a stroke at all.
        #if targetEnvironment(simulator)
        canvasView.drawingPolicy = .anyInput
        #else
        canvasView.drawingPolicy = .pencilOnly
        #endif

        // The canvas is the ink and nothing else; the paper is `paperView`
        // beneath it, so the canvas has to be clear for the paper to show.
        // The surround is clear too: the ground belongs to the paging scroll
        // view underneath, and a second copy of it here would break the
        // grid's register at every slot boundary.
        view.backgroundColor = .clear
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false

        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.contentInsetAdjustmentBehavior = .never

        // `bouncesZoom` stays true, and the reason is a device finding
        // (2026-08-08, iPad Air 5): with the canvas sitting exactly at its zoom
        // floor — which is where every page opens — `false` killed pinch zoom
        // outright. Not stiff at the limit: dead, in either direction. The
        // price paid back is that a rubber-band can briefly present a scale
        // past the limit while the model reads the limit.
        canvasView.bouncesZoom = true

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        backdropView.isOpaque = true
        backdropView.backgroundColor = MacaronPage.paper
        backdropView.contentMode = .scaleToFill
        backdropView.layer.borderColor = MacaronPage.outline.cgColor
        backdropView.clipsToBounds = true
        backdropView.frame = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        paperView.isUserInteractionEnabled = false
        paperView.addSubview(backdropView)
        view.insertSubview(paperView, belowSubview: canvasView)
        view.addSubview(overlayView)
        syncPageMirrors()

        // Allowed to recognize alongside PencilKit's own: a tap that is not on
        // a link must still reach the canvas, and a tap that is must not have
        // to win a race to be reported.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        canvasView.addGestureRecognizer(tap)

        if let tool { apply(tool: tool) }

        // A finger-typed session is covered by the keyboard on the first
        // keystroke without this.
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let showing = notification.name == UIResponder.keyboardWillShowNotification
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardWillChange(showing: showing, frame: frame) }
            })
        }
    }

    /// The theme changed under it. The frame's geometry is restated by the
    /// next mirror sync; only the two colours are read again here.
    func repaintPaper() {
        backdropView.backgroundColor = MacaronPage.paper
        backdropView.layer.borderColor = MacaronPage.outline.cgColor
    }

    package override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        establishZoomIfNeeded()
        centerPageInViewport()
        syncPageMirrors()
    }

    /// Places both mirrors where the canvas's content is: page points scaled
    /// by the zoom, with the page's origin where the scroll view shows it.
    /// Bounds stay in page points so every subview keeps its page-space
    /// frame; the transform is what carries the zoom.
    private func syncPageMirrors() {
        let zoom = canvasView.zoomScale
        let size = CGSize(width: geometry.width, height: geometry.height)
        let offset = canvasView.contentOffset
        let center = CGPoint(
            x: canvasView.frame.minX - offset.x + size.width * zoom / 2,
            y: canvasView.frame.minY - offset.y + size.height * zoom / 2
        )
        for mirror in [paperView, overlayView] {
            mirror.bounds = CGRect(origin: .zero, size: size)
            mirror.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            mirror.center = center
        }
        // The mirror carries the zoom, so the frame's radius and line are
        // written in page points divided by it: 10 and 3 on the glass at
        // every zoom, which is what the design fixes them at.
        let divisor = max(zoom, 0.0001)
        backdropView.layer.cornerRadius = MacaronPage.radius / divisor
        backdropView.layer.borderWidth = MacaronPage.lineWidth / divisor
    }

    package func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncPageMirrors()
    }

    package func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncPageMirrors()
    }

    // MARK: - Told, never asked

    /// A sharper or refreshed backdrop. Ink is untouched, at every zoom.
    func updateComposite(_ composite: Composite) {
        backdropView.image = UIImage(cgImage: composite.image)
    }

    /// The layer list the picture was rendered from, which is also what the
    /// selection is rebuilt against: a selected layer the list still names is
    /// restated at whatever placement the notebook now holds, and one the
    /// list no longer names takes the frame down with it. That is how a
    /// delete, an undo, and a restore all reach the frame — through the
    /// composite, with nothing else to keep in step.
    func setLayers(_ layers: [Layer]) {
        hitTargets = layers.map { layer in
            switch layer.payload {
            case .link(let link):
                HitTarget(id: layer.id, kind: .link, transform: .unitSquare(to: link.rect), locked: layer.locked)
            case .text(let text):
                HitTarget(id: layer.id, kind: .text, transform: .unitSquare(to: text.rect), locked: layer.locked)
            case .image:
                HitTarget(id: layer.id, kind: .image, transform: layer.transform, locked: layer.locked)
            case .pdf:
                HitTarget(id: layer.id, kind: .pdf, transform: layer.transform, locked: layer.locked)
            }
        }
        guard case .selected(let selected, let frame) = phase else { return }
        if let target = hitTargets.first(where: { $0.id == selected }) {
            frame.adopt(target.transform)
            frame.setLocked(target.locked)
        } else {
            clearSelection()
        }
    }

    /// The drawing gesture follows the tool, not the session: there is no
    /// window where the text tool is selected and the Pencil draws. Switching
    /// to ink commits an open session before the gesture comes back, so a
    /// stroke never lands under a live overlay.
    func apply(tool: CanvasTool) {
        self.tool = tool
        switch tool {
        case .ink(let pkTool):
            commitSession()
            // A selection belongs to the lasso and to nothing else, so every
            // other arm drops it. Lasso to lasso keeps it.
            if !(pkTool is PKLassoTool) { clearSelection() }
            canvasView.tool = pkTool
            canvasView.drawingGestureRecognizer.isEnabled = true
        case .text(let style, let alignment):
            clearSelection()
            canvasView.drawingGestureRecognizer.isEnabled = false
            if case .editing(_, let view) = phase {
                view.applyStyle(style, alignment: alignment)
            }
        }
    }

    /// The omitting composite has landed; the overlay goes up over it.
    ///
    /// A begin the runtime cannot honour, because a tool switch or a retire
    /// raced the render, is answered with the value unchanged: the notebook's
    /// session closes the one way a session closes, and the picture regains
    /// the layer.
    func beginTextEditing(_ start: TextEditStart) {
        guard case .opening = phase else {
            owner.pageDidEndTextEditing(pageID, layer: start.layer, start.text)
            return
        }
        let typing: TextStyle = if case .text(let style, _) = tool { style } else { .body }
        let view = TextEditingView(text: start.text, typing: typing)
        overlayView.addSubview(view)
        setOverlayScale(view)
        // A border drag neither pans the page nor turns it. Turning the page
        // would retire this canvas and destroy the view mid-gesture.
        for pan in [canvasView.panGestureRecognizer, owner.pagingPanGestureRecognizer()].compactMap({ $0 }) {
            pan.require(toFail: view.moveRecognizer)
            pan.require(toFail: view.resizeRecognizer)
        }
        phase = .editing(layer: start.layer, view: view)
        view.becomeFirstResponder()
        TNLog.event(.canvas, "text editing began on page \(pageID)")
    }

    /// The committed composite has landed; the inert overlay comes down. An
    /// end for a layer with no overlay coming down answers a begin instead:
    /// the notebook refused it because the tap landed on a rect a restore
    /// had already removed, and the session it never opened is over.
    func endTextEditing(layer: LayerID) {
        if closing[layer] == nil, case .opening = phase { phase = .idle }
        closing.removeValue(forKey: layer)?.removeFromSuperview()
    }

    /// Typing's undo is the text view's own manager, which it supplies only
    /// while it is first responder. Resigned, `undoManager` walks the chain
    /// to `filteringUndoManager`, whose undo reports back up and would
    /// arrive here again; so a resigned view answers nothing, as `.opening`
    /// does with no view at all.
    func undoTyping() {
        if case .editing(_, let view) = phase, view.isFirstResponder { view.undoManager?.undo() }
    }

    func redoTyping() {
        if case .editing(_, let view) = phase, view.isFirstResponder { view.undoManager?.redo() }
    }

    /// Reports the draft whole and leaves the view up, inert, until the
    /// composite that has the text lands. State settles before the report
    /// leaves.
    private func commitSession() {
        guard case .editing(let layer, let view) = phase else { return }
        view.resignFirstResponder()
        closing[layer] = view
        phase = .idle
        TNLog.event(.canvas, "text editing ended on page \(pageID)")
        owner.pageDidEndTextEditing(pageID, layer: layer, view.committedLayer)
    }

    /// Glyphs rasterize at the zoom, once per gesture, never per frame.
    private func setOverlayScale(_ view: UIView) {
        let scale = canvasView.zoomScale * traitCollection.displayScale
        view.contentScaleFactor = scale
        for subview in view.subviews { subview.contentScaleFactor = scale }
    }

    package func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        switch phase {
        case .editing(_, let overlay): setOverlayScale(overlay)
        case .selected(_, let frame): setOverlayScale(frame)
        case .idle, .opening: break
        }
        for overlay in closing.values { setOverlayScale(overlay) }
    }

    // MARK: - Keyboard

    func keyboardWillChange(showing: Bool, frame: CGRect?) {
        guard isViewLoaded, let window = view.window else { return }
        var overlap: CGFloat = 0
        if showing, let frame {
            let covered = view.convert(frame, from: window).intersection(view.bounds)
            overlap = covered.isNull ? 0 : covered.height
        }
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        centerPageInViewport()
        if overlap > 0, case .editing(_, let overlay) = phase {
            let zoom = canvasView.zoomScale
            canvasView.scrollRectToVisible(overlay.frame.applying(CGAffineTransform(scaleX: zoom, y: zoom)), animated: true)
        }
    }

    func setUndoAvailability(canUndo: Bool, canRedo: Bool) {
        filteringUndoManager.setAvailability(canUndo: canUndo, canRedo: canRedo)
    }

    /// The page's geometry changed under it — a re-import, a resized page. Rare
    /// enough to be a full re-establish rather than an incremental one.
    func updateGeometry(_ geometry: PageGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        canvasView.contentSize = CGSize(width: geometry.width, height: geometry.height)
        backdropView.frame = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        syncPageMirrors()
        // The overlay's frame is its rect in page space, which a geometry
        // change does not move.
        zoomRangeBounds = nil
        view.setNeedsLayout()
    }

    /// An install, never an edit: the value is set and the same sequence number
    /// is stamped on the report PencilKit fires for it, so the notebook drops
    /// its own echo instead of taking it for a stroke.
    func restoreInk(_ ink: PKDrawing, seq: InkSeq) {
        TNPrecondition.require(
            !isStrokeInFlight,
            "ink was installed on page \(pageID) while a stroke was in flight"
        )
        inkSeq = seq
        pendingEcho = seq
        canvasView.drawing = ink
        clearEchoLatchAtEndOfTurn(seq)
    }

    /// The latch clears on the first change after the set or at the end of the
    /// turn, whichever comes first.
    private func clearEchoLatchAtEndOfTurn(_ seq: InkSeq?) {
        guard let seq else { return }
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, self.pendingEcho == seq else { return }
            self.pendingEcho = nil
        }
    }

    // MARK: - The one retire path

    /// Delivers the final ink report synchronously and records that it did.
    ///
    /// Refusable: while a stroke is in flight it answers `.deferred` and the
    /// owner retires it again when the stroke ends. Never interrupt a stroke.
    func retire() -> RetireOutcome {
        if isStrokeInFlight { return .deferred }
        guard !hasRetired else { return .retired }
        // The draft goes home before the ink does. A session still opening
        // has no draft; the begin that arrives later finds no canvas, and the
        // owner answers it.
        commitSession()
        // A selection is not a value, so nothing is reported for it.
        clearSelection()
        phase = .idle
        for view in closing.values { view.removeFromSuperview() }
        closing.removeAll()
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
        keyboardObservers.removeAll()
        hasRetired = true
        canvasView.delegate = nil
        owner.pageDidRetire(pageID, finalInk: canvasView.drawing)
        return .retired
    }

    // MARK: - Zoom

    /// The zoom floor is this page's own fit scale, and the ceiling is the
    /// document's detail cap.
    ///
    /// Per page, not per document: a shared *scale* across pages of different
    /// sizes would mean turning the page changes how much of a page you can
    /// see.
    private func establishZoomIfNeeded() {
        let bounds = canvasView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds != zoomRangeBounds else { return }

        let fit = PageFit.scale(geometry, in: bounds)
        guard fit > 0, fit.isFinite else { return }

        // The scale the previous viewport was showing, carried across a resize
        // so a Split View drag does not also re-zoom the page.
        let ratio = zoomRangeBounds.map { canvasView.zoomScale / PageFit.scale(geometry, in: $0) } ?? 1

        let displayScale = Double(max(traitCollection.displayScale, 1))
        // The cap is the smaller of what the document promises at this display
        // scale and what PencilKit will actually deliver. On every supported
        // iPad — 2x — the two are the same number, 10. A coarser display asks
        // for more than PencilKit gives, and taking the minimum is what keeps
        // the range valid there instead of trapping for a screen the promise
        // was never made about.
        let ceiling = min(ZoomCap.runtimeMaximumZoomScale, ZoomCap.maximumZoomScale(displayScale: displayScale))

        // A page so small that fitting it already exceeds the deepest zoom the
        // document allows would open above its own ceiling. `PageBounds.minEdge`
        // is derived so this cannot happen on a supported viewport; this is the
        // one place it could be observed failing.
        TNPrecondition.require(
            CGFloat(ceiling) >= fit,
            "page \(geometry.width)x\(geometry.height) fits at \(fit), past the zoom ceiling \(ceiling)"
        )

        // Order matters: the range must admit the new scale before it is set,
        // or UIScrollView clamps it to the range still describing the old
        // viewport.
        canvasView.minimumZoomScale = fit
        canvasView.maximumZoomScale = CGFloat(ceiling)
        // Measured, undocumented, and invisible unless something reads the
        // value back: PKCanvasView silently clamps `maximumZoomScale` at 10. A
        // document that pinned a deeper cap would promise a detail level the
        // canvas quietly does not deliver, so the read-back traps here.
        TNPrecondition.require(
            abs(Double(canvasView.maximumZoomScale) - ceiling) < 1e-6,
            "the zoom cap asks for a maximum zoom scale of \(ceiling) and PKCanvasView accepted "
                + "\(canvasView.maximumZoomScale)"
        )
        canvasView.zoomScale = min(max(fit * ratio, canvasView.minimumZoomScale), canvasView.maximumZoomScale)
        zoomRangeBounds = bounds
    }

    /// Keeps the page centred once it is smaller than the viewport.
    ///
    /// `contentInset` is the mechanism rather than a content transform, because
    /// it moves only where the scroll view may rest, leaving content
    /// coordinates — and therefore page space, the backdrop, and every layer
    /// rect — alone.
    private func centerPageInViewport() {
        let bounds = canvasView.bounds.size
        let content = canvasView.contentSize
        let horizontal = max(0, (bounds.width - content.width) / 2)
        let vertical = max(0, (bounds.height - content.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: max(vertical, keyboardOverlap), right: horizontal)
        guard canvasView.contentInset != inset else { return }
        canvasView.contentInset = inset
    }

    // MARK: - Taps

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let zoom = canvasView.zoomScale
        guard zoom > 0 else { return }
        // `location(in:)` on a scroll view answers in zoomed content
        // coordinates; page space is that divided by the scale.
        let point = recognizer.location(in: canvasView)
        tapped(at: CGPoint(x: point.x / zoom, y: point.y / zoom))
    }

    /// A tap in page space. With the text tool a text rect is edited and
    /// paper gets a box, either one after the open session commits; with the
    /// lasso an object is selected; with any other ink tool a link is
    /// activated.
    ///
    /// Objects answer the lasso alone. A Pencil writing over a photo or a
    /// worksheet must never pick it up instead, and this recognizer does not
    /// know the touch's type.
    func tapped(at pagePoint: CGPoint) {
        switch tool {
        case .text(let style, let alignment):
            guard let hit = Self.textHit(at: pagePoint, targets: hitTargets) else { return }
            commitSession()
            phase = .opening
            switch hit {
            case .edit(let layer):
                owner.pageDidRequestTextEdit(pageID, layer: layer)
            case .create(let point):
                owner.pageDidRequestTextBox(pageID, at: point, style: style, alignment: alignment)
            }
        case .ink(let pkTool) where pkTool is PKLassoTool:
            selectObject(at: pagePoint)
        case .ink, nil:
            guard let hit = Self.linkHit(at: pagePoint, targets: hitTargets) else { return }
            TNLog.event(.canvas, "link activated on page \(pageID)")
            owner.pageDidActivateLink(pageID, layer: hit)
        }
    }

    /// Topmost first: the stack is bottom-to-top and the layer a finger lands
    /// on is the one drawn last. A link under the text tool is nothing, and
    /// an image or a PDF clipping is paper — a box goes on top of it, which
    /// is why an image over a text box gets a new box rather than opening
    /// the one it hides.
    static func textHit(at point: CGPoint, targets: [HitTarget]) -> TextTap? {
        guard let hit = Self.topmost(at: point, targets: targets) else {
            return .create(PagePoint(x: point.x, y: point.y))
        }
        switch hit.kind {
        case .text: return .edit(hit.id)
        case .link: return nil
        case .image, .pdf: return .create(PagePoint(x: point.x, y: point.y))
        }
    }

    static func linkHit(at point: CGPoint, targets: [HitTarget]) -> LayerID? {
        targets.last { $0.kind == .link && $0.transform.contains(PagePoint(x: point.x, y: point.y)) }?.id
    }

    static func topmost(at point: CGPoint, targets: [HitTarget]) -> HitTarget? {
        targets.last { $0.transform.contains(PagePoint(x: point.x, y: point.y)) }
    }

    // MARK: - Selection

    /// A tap with the lasso. An image or a PDF clipping under it is selected,
    /// paper clears the selection, and a link or a text box is neither: they
    /// have no transform to move, so a tap on one leaves whatever is selected
    /// alone.
    private func selectObject(at pagePoint: CGPoint) {
        guard let target = Self.topmost(at: pagePoint, targets: hitTargets) else {
            clearSelection()
            return
        }
        switch target.kind {
        case .link, .text:
            return
        case .image, .pdf:
            if case .selected(let current, _) = phase, current == target.id { return }
            select(target)
        }
    }

    private func select(_ target: HitTarget) {
        clearSelection()
        let frame = LayerSelectionView(layer: target.id, transform: target.transform, locked: target.locked)
        overlayView.addSubview(frame)
        setOverlayScale(frame)
        // A drag on the frame neither draws, nor pans the page, nor turns it.
        // Turning would retire this canvas and destroy the view mid-gesture.
        let contenders = [
            canvasView.panGestureRecognizer,
            canvasView.drawingGestureRecognizer,
            owner.pagingPanGestureRecognizer(),
        ].compactMap { $0 }
        for recognizer in contenders { recognizer.require(toFail: frame.panRecognizer) }
        frame.onDragEnded = { [weak self] transform in self?.reportTransform(of: frame, to: transform) }
        frame.onDeleteRequested = { [weak self] in
            guard let self else { return }
            self.owner.pageDidRequestLayerDelete(self.pageID, layer: frame.layerID)
        }
        frame.onLockRequested = { [weak self] locked in
            guard let self else { return }
            self.owner.pageDidRequestLayerLock(self.pageID, layer: frame.layerID, locked: locked)
        }
        phase = .selected(layer: target.id, view: frame)
        TNLog.event(.canvas, "object selected on page \(pageID)")
    }

    /// The drag's one report. A refusal is answered by restating the
    /// placement the notebook holds; an acceptance is answered by the
    /// composite that follows, which restates the same value through
    /// `setLayers`.
    private func reportTransform(of frame: LayerSelectionView, to transform: PageSpaceTransform) {
        let outcome = owner.pageDidTransformLayer(pageID, layer: frame.layerID, to: transform)
        if case .refused = outcome { frame.adopt(frame.accepted) }
    }

    private func clearSelection() {
        guard case .selected(_, let frame) = phase else { return }
        frame.removeFromSuperview()
        phase = .idle
    }

    package func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Caret placement and selection inside the live box are the text
    /// view's. This also kills the re-begin loop where a tap in the open
    /// box's own rect would request the layer already open.
    package func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        switch phase {
        case .idle, .opening:
            return true
        case .editing(_, let view):
            return !view.bounds.contains(gestureRecognizer.location(in: view))
        case .selected(_, let frame):
            // The frame has its own tap, which opens the menu. This one would
            // otherwise re-select the object under it, or clear it.
            return !frame.point(inside: gestureRecognizer.location(in: frame), with: nil)
        }
    }

    // MARK: - PKCanvasViewDelegate

    package func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isStrokeInFlight = true
        awaitingChangeAfterToolUse = false
    }

    package func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard isStrokeInFlight else { return }
        awaitingChangeAfterToolUse = true
        // The drawing change that commits the stroke normally follows in this
        // same turn. A tool use that commits nothing — a tap with the eraser on
        // empty paper — fires no change at all, and without this the flag would
        // stay set and every deferred install would wait forever.
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, self.awaitingChangeAfterToolUse else { return }
            self.awaitingChangeAfterToolUse = false
            self.isStrokeInFlight = false
            self.owner.pageStrokeDidEnd(self.pageID)
        }
    }

    /// Reported for every drawing mutation, one report per PencilKit callback.
    /// The runtime does not classify them: the notebook owns save policy, and
    /// the echo latch is the only thing said here about where a change came
    /// from.
    package func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let echo = pendingEcho
        pendingEcho = nil

        // The state change finishes before the report leaves: a handler that
        // installs, retires, or turns the page must see a canvas with no stroke
        // in flight.
        let strokeEnded = awaitingChangeAfterToolUse
        if strokeEnded {
            awaitingChangeAfterToolUse = false
            isStrokeInFlight = false
        }

        owner.pageDidChangeInk(pageID, canvasView.drawing, echoOf: echo)
        if strokeEnded {
            owner.pageStrokeDidEnd(pageID)
        }
    }
}

/// A page-sized container that is nothing to a touch: a tap on it between its
/// subviews reaches the canvas under it, a tap on a subview is that subview's.
final class PageMirrorView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

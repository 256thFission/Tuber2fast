import PencilKit
import TuberCore
import TuberModel
import TuberRender
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
package final class PageCanvasController: UIViewController, PKCanvasViewDelegate {
    /// The ink surface. A `PKCanvasView` subclass for one reason — it refuses
    /// PencilKit's editing menu; see `InkCanvasView`.
    let canvasView = InkCanvasView()

    /// Open question, measured rather than guessed: does the mirrored backdrop
    /// stay registered with the ink through a fast pinch? See
    /// `ZoomRegistrationProbe`, and delete both once the answer lands.
    private let zoomProbe = ZoomRegistrationProbe()

    /// Whoever placed this page, and the only thing this controller reports to.
    ///
    /// Non-optional and supplied at construction: a page canvas that reports
    /// nowhere is a page whose ink is edited and never saved, and that state
    /// no longer exists to be reached. See `PageCanvasHost`, which also states
    /// why this reference is strong.
    private let host: any PageCanvasHost

    /// Shared across pages and owned by `PagedCanvasController`. One picker per
    /// page would mean the selected tool resetting every time you turn one.
    private let toolPicker: PKToolPicker

    /// Which page this controller's drawing belongs to, told at construction.
    ///
    /// **Told, never asked** (`Contract.md` — Owners, golden rule 7). It is an
    /// identity and not a position: this controller still knows nothing about
    /// page numbers, page order, or turns, and it never looks this ID up in
    /// anything. It exists so the composite requests below name the page whose
    /// texture they are — which is what lets the render cache evict by page,
    /// and what lets a page with no static layers have a cached composite at
    /// all.
    private let pageID: UUID

    /// This page's own size and the document's zoom cap, told at construction
    /// and never changed (`Contract.md` — Geometry and coordinates: geometry is
    /// per page, set at page creation, immutable afterward).
    ///
    /// `let`, which is the enforcement: there is no setter, so "no owner mutates
    /// geometry after creation" is a property of the type rather than a rule
    /// this file remembers. A page whose geometry changed would be a page whose
    /// ink moved under it.
    private let projection: PageProjection

    private var geometry: PageGeometry { projection.geometry }

    /// The viewport size the current zoom range was computed for, or `nil`
    /// before the first layout. Keyed on the size rather than on a bool so that
    /// repeated layout passes at one size change nothing, while a genuine
    /// viewport change — rotation, Split View — re-fits. See
    /// `establishZoomIfNeeded`.
    private var zoomRangeBounds: CGSize?

    /// A hairline showing where the page ends.
    ///
    /// Presentation only: it is not ink, is never part of the drawing, and is
    /// not persisted. It crisps the seam between the white paper and the dark
    /// gutter, and survives from the era when both were white and the page
    /// was otherwise invisible.
    ///
    /// A layer, not a view, and that is load-bearing. `PKCanvasView` is a
    /// `UIScrollView`, and a scroll view delays and re-delivers touches to its
    /// subviews. Adding a subview put this decoration into that bookkeeping and
    /// crashed UIKit inside `_delayTouchesForEvent:` on the first Pencil stroke.
    /// Layers never participate in touch handling, so they cannot perturb it.
    private let pageBoundary = CALayer()

    /// The dark margins: four opaque strips framing the page rect, so the
    /// gutter's dark is what shows wherever the paper is not (device verdict,
    /// 2026-08-08 — margins are universally dark, "it's neater").
    ///
    /// Strips *around* the page and not a ground *behind* it, and the reason
    /// is a measured PencilKit behaviour: an opaque `PKCanvasView` paints its
    /// `backgroundColor` through its own tiled content view, over any sublayer
    /// slipped beneath it — a dark canvas ground turned the paper itself dark
    /// on device. So the canvas background stays the paper white, opaque and
    /// blend-free, and the dark is painted only where ink cannot be: outside
    /// the content rect, in the inset room. Four plain layers, framed in the
    /// same transaction as the hairline — frame assignments only, nothing
    /// allocated on a zoom frame. The same layer-not-view reasoning as
    /// `pageBoundary` applies.
    private let marginShades = [CALayer(), CALayer(), CALayer(), CALayer()]

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

    // MARK: - Static layers, beneath the ink

    /// Flattens this page's static layers into one texture, off-main. `nil` in
    /// a runtime built without one — a test, or any host that has no document
    /// behind it — in which case a page simply shows no backdrop.
    private let staticRenderer: StaticLayerRenderer?

    /// The mirrored sibling stack, built only once this page has something to
    /// put in it. A page with no static layers has no backdrop object, no
    /// layers, and no transparency — which is what keeps the blank-page path
    /// exactly as cheap as it is today.
    private(set) var backdrop: PageBackdrop?

    /// This page's recognized layers below the ink, in order. Told by
    /// `PagedCanvasController`, which is told by `EditorSession` — the one
    /// writer of the list (`Contract.md` — Owners, golden rule 5). Held here
    /// only to know what to render.
    private var staticLayers: [LayerEnvelope] = []

    /// Selection and the transform gesture, built only for a page that carries
    /// something selectable. See `LayerSelectionRuntime`: like the shape tool
    /// and the backdrop it is this controller's own runtime rather than a
    /// second owner, and it hands one committed transform back per gesture.
    ///
    /// `nil` on a page with no `image` layer, which is what makes "with no
    /// selection, every touch behaves exactly as today" true of the recognizer
    /// list itself rather than of a delegate's judgement.
    private(set) var selection: LayerSelectionRuntime?

    /// The three background pipelines this controller owns, held so that work
    /// nobody will install stops rather than merely being ignored
    /// (`CONTRIBUTING.md` — Cancellation). Each is cancelled by its own
    /// supersession and all three by `willRetire`, which is the five-page
    /// flick: a page that left the live window decodes nothing more.
    ///
    /// The generation counters below survive alongside them, and that is the
    /// rule rather than an oversight: cancellation is asynchronous, so a
    /// decode that finished microseconds before the cancel landed is still a
    /// completed result looking for somewhere to go. The counter is what makes
    /// installing it impossible; the cancel is what stops the work.
    private var liftTask: Task<Void, Never>?
    private var compositeTask: Task<Void, Never>?
    private var lensTask: Task<Void, Never>?

    /// Increments on every lifted-source request, so an image that arrives
    /// after the selection moved on is dropped rather than shown.
    private var liftGeneration = 0

    /// The layer the backdrop's lift is currently drawing, or `nil` when
    /// nothing is lifted. The lift may only be replaced or dropped once the
    /// composite on screen re-includes this layer — `PageBackdrop`'s own
    /// invariant that excluding a layer is only safe once something else draws
    /// it.
    private var liftedLayerID: UUID?

    /// A decoded lift waiting for the composite that re-includes the
    /// *previous* lifted layer. Switching the selection A→B must not replace
    /// A's lift while A is still excluded from the composite on screen — that
    /// is a window in which A is drawn nowhere. The swap happens in
    /// `requestCompositeIfNeeded`'s completion, synchronously with showing the
    /// composite that contains A again, so no frame renders between them.
    private var pendingLift: (image: CGImage, layer: LayerEnvelope)?

    /// The request currently rendering or rendered, so a repeated layout pass
    /// at one size asks for nothing.
    ///
    /// **Dedup, not staleness** (`CONTRIBUTING.md` — Cancellation): it answers
    /// "is this already asked for?", which is why an equal request must not
    /// cancel the one in flight — that would restart the identical decode on
    /// every layout pass. Staleness here is `compositeGeneration`'s job.
    private var renderedRequest: StaticLayerRequest?

    /// The last composite request this controller issued, read only by tests:
    /// the minus-one wiring — selection feeding the composite request — is
    /// otherwise observable only by pixel diffing.
    // Debug-only, as every `…ForTesting` member is; the reasoning is at
    // `EditorSession.staticRendererForTesting`.
    #if DEBUG
    var renderedRequestForTesting: StaticLayerRequest? { renderedRequest }
    #endif

    /// Increments on every composite request, so an answer that arrives after
    /// the page's layers changed is dropped rather than shown. A late render
    /// shows the placeholder or a scaled base — never a wrong picture.
    private var compositeGeneration = 0

    /// Increments whenever the settled state a lens was asked for stops being
    /// the state on screen — a new gesture, a layer edit, a viewport change.
    /// A lens that lands under a stale generation is dropped, never shown: a
    /// sharp patch at the wrong position is worse than the soft base.
    private var lensGeneration = 0

    /// How many lens renders this controller has asked for, and the last ask.
    /// Read only by tests: "the lens is requested at settle and never by a
    /// gesture frame" and "the visible rect is clamped to the page" are
    /// otherwise observable only on a device.
    #if DEBUG
    private(set) var lensRequestCountForTesting = 0
    private(set) var lensRequestForTesting: (rect: CGRect, pixelsPerPagePoint: Double)?
    #endif

    /// A lens is only worth rendering meaningfully past the base's own
    /// detail; below this ratio the base is already pixel-exact or close
    /// enough that a second texture buys nothing.
    private static let lensWorthwhileFactor = 1.25

    /// The composite's long edge, in pixels, at the level-of-detail cap.
    ///
    /// 2,800 px is a little over the long edge of the largest iPad's display,
    /// so a page rendered at the cap is still pixel-exact at fit-width on every
    /// device this ships to, and a composite costs at most about 24 MB. Deeper
    /// zoom shows this texture scaled and slightly soft, exactly as every PDF
    /// viewer on iOS does; the base-and-lens split that makes deep zoom sharp
    /// is phase 3 and needs its own device spike.
    private static let maximumCompositeLongEdge: Double = 2800

    init(
        pageID: UUID,
        toolPicker: PKToolPicker,
        projection: PageProjection,
        host: any PageCanvasHost,
        staticRenderer: StaticLayerRenderer? = nil
    ) {
        self.pageID = pageID
        self.toolPicker = toolPicker
        self.projection = projection
        self.host = host
        self.staticRenderer = staticRenderer
        super.init(nibName: nil, bundle: nil)

        // Page space and change reporting are established before the view
        // loads. Wiring them in `viewDidLoad` would mean a canvas that has not
        // yet been displayed silently reports no changes — the document would
        // take edits it never saved.
        //
        // Assigned unzoomed, which is correct because `zoomScale` is still 1
        // here and `UIScrollView` scales `contentSize` itself whenever the scale
        // changes. Nothing writes `contentSize` again: this page's geometry is
        // fixed for its life, so this is the only assignment it ever needs.
        canvasView.contentSize = CGSize(width: geometry.width, height: geometry.height)
        canvasView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageCanvasController is created in code only")
    }

    package override func viewDidLoad() {
        super.viewDidLoad()

        // The canvas is the page: its content coordinate system is page space,
        // so ink is authored in page points regardless of zoom or view size.
        // `contentSize` and the delegate are established in `init`.
        //
        // White and opaque, and it must stay both: this background *is* the
        // paper — PencilKit's opaque tiled view paints it through everything
        // (see `marginShades` for the device finding) — and opaque is the
        // blank-page path's freedom from a full-screen blend. The dark
        // margins are the strips, never this colour.
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true

        // Finger navigates, Pencil writes.
        canvasView.drawingPolicy = .pencilOnly

        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        // **`bouncesZoom` stays `true`, and the reason is a device finding.**
        // It was set to `false` after the 2026-08-07 round-2 session, on two
        // arguments — no dead space flashing below the floor, and the bounce
        // being the one state where the presented scale and the reported scale
        // disagree under the mirror. Neither was ever felt on hardware, and on
        // 2026-08-08 Phillip found the actual price: with the canvas sitting
        // exactly at its floor — which is where every page opens — `false`
        // killed pinch zoom outright. Not stiff at the limit: dead. No pinch
        // registered in either direction.
        //
        // So the trade reverses, priced honestly: the rubber-band can again
        // briefly show past-the-limit scale, and during that bounce the mirror
        // follows the model while the ink follows the presentation —
        // `ZoomRegistrationProbe` is still in place to say whether that
        // disagreement is the visible "ink catching up" or a rounding error.
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
        //
        // The shades go in before the selection chrome ever installs, so
        // handles that overhang a page edge still draw above the margins.
        // Resolved against the current traits, as `pageBoundary`'s colour is.
        for shade in marginShades {
            shade.backgroundColor = UIColor.systemGray5.resolvedColor(
                with: traitCollection
            ).cgColor
            canvasView.layer.addSublayer(shade)
        }
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

        // A page whose layer list was set before its view loaded — every page
        // built by `PagedCanvasController`, which configures the controller and
        // then lets layout force the view.
        if !staticLayers.isEmpty {
            installBackdropIfNeeded()
            installSelectionIfNeeded()
            selection?.setLayers(staticLayers)
        }
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
        let pageRect = CGRect(
            x: 0,
            y: 0,
            width: geometry.width * scale,
            height: geometry.height * scale
        )
        // Far larger than any inset room a viewport can open around the page,
        // so the strips never run out however the page is centred.
        let pad: CGFloat = 4096
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageBoundary.borderWidth = 1 / max(traitCollection.displayScale, 1)
        pageBoundary.frame = pageRect
        // Left and right run tall to take the corners; top and bottom span
        // only the page's width between them.
        marginShades[0].frame = CGRect(
            x: pageRect.minX - pad, y: -pad, width: pad, height: pageRect.height + 2 * pad
        )
        marginShades[1].frame = CGRect(
            x: pageRect.maxX, y: -pad, width: pad, height: pageRect.height + 2 * pad
        )
        marginShades[2].frame = CGRect(
            x: pageRect.minX, y: -pad, width: pageRect.width, height: pad
        )
        marginShades[3].frame = CGRect(
            x: pageRect.minX, y: pageRect.maxY, width: pageRect.width, height: pad
        )
        CATransaction.commit()
    }

    /// Takes keyboard focus so the shared tool picker shows for this page.
    /// Called by `PagedCanvasController` when this page becomes the visible one;
    /// a page that is merely prepared alongside it must not steal focus.
    func becomeActivePage() {
        canvasView.becomeFirstResponder()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        // After becoming first responder, because that is when PencilKit has
        // reason to have installed its menu machinery. Once per page
        // activation, off every frame path. The *presenter* is deliberately
        // left in place — the lasso's cut/copy/delete needs it; only the
        // context-menu bridge that raises it on a tap is taken.
        let removed = canvasView.removeContextMenuBridge()
        CanvasLog.event(
            .canvas,
            "appeared; firstResponder=\(canvasView.isFirstResponder) "
                + "policy=\(canvasView.drawingPolicy.rawValue) "
                + "contentSize=\(canvasView.contentSize) zoom=\(canvasView.zoomScale) "
                + "contextMenuBridgesRemoved=\(removed) "
                + "editMenuPresenterKept=\(canvasView.hasEditMenuPresenter)"
        )
        if !Self.hasLoggedMenuMachinery {
            Self.hasLoggedMenuMachinery = true
            CanvasLog.event(.canvas, "menu machinery: \(canvasView.describeMenuMachinery())")
        }
    }

    /// The interaction/gesture inventory is logged once per process, not once
    /// per page: it is a fact about `PKCanvasView`, and five live canvases would
    /// otherwise write the same paragraph five times. Main-actor isolated with
    /// the rest of the type, so nothing is implied by it being static.
    private static var hasLoggedMenuMachinery = false

    /// The first touch to reach the canvas, and nothing after it.
    ///
    /// This exists to answer one question the crash reports could not: whether
    /// the app survives long enough to see a touch at all. It is not a
    /// per-sample hook — it logs once and then never again.
    package override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !hasLoggedFirstTouch else { return }
        hasLoggedFirstTouch = true
        let types = touches.map { "\($0.type.rawValue)" }.joined(separator: ",")
        CanvasLog.event(.canvas, "first touch reached the canvas; types=[\(types)]")
    }

    package override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        establishZoomIfNeeded()
        centerPageInViewport()
        // Establishes initial registration and re-registers after a viewport
        // change; not a frame-frequency path.
        backdrop?.viewportChanged(to: view.bounds)
        backdrop?.mirror(offset: canvasView.contentOffset, zoom: canvasView.zoomScale)
        // A viewport change is a level-of-detail change — a rotation moves
        // fit-width — so the composite is re-asked for here and nowhere near a
        // gesture.
        requestCompositeIfNeeded()
    }

    /// Establishes the zoom range for the current viewport, and re-establishes
    /// it when the viewport itself changes size.
    ///
    /// **The floor is fit-page** — `min(fitWidth, fitHeight)` — and the page
    /// **opens at the floor** (`Contract.md` — Geometry and coordinates: the
    /// floor derives from the fixed page). Two device verdicts, one from each
    /// orientation, and the min is what honors both:
    ///
    /// - Portrait, 2026-08-07: no dead space beside the page. For a page
    ///   taller than the viewport's aspect, fit-height exceeds fit-width, so
    ///   the min *is* fit-width there and nothing this verdict refused comes
    ///   back — including the opening scale, which is unchanged in portrait.
    /// - Landscape, 2026-08-08 (reachable only since the portrait pin lifted
    ///   that morning): a fit-width floor left the full extent of the page
    ///   unreachable, and a fit-width *opening* dropped the reader into the
    ///   middle of a page they had not seen yet. A page arrives whole — its
    ///   top and bottom on screen — and the side room that appears is
    ///   `centerPageInViewport`'s to split evenly. Zooming to fit-width to
    ///   write is one pinch, and it is the user's pinch.
    ///
    /// The earlier floor — fit the whole page *with overview room to spare* —
    /// stays gone: the floor shows all of the page and not one point of grey
    /// past it.
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
    /// the scale is carried across as a ratio of fit-page, so a page examined
    /// at twice the floor is still at twice the floor after a rotation. On the
    /// first pass the ratio is 1, so opening at the floor is the same code path.
    ///
    /// **The floor derives from this page**, not from a global — which is what
    /// per-page geometry changes here. A landscape page fits its own width; a
    /// portrait neighbour does the same with different numbers, and neither
    /// reads the other's.
    ///
    /// **The ceiling derives from the document's durable cap and nothing else.**
    /// It was `fitWidth × 8` — a function of the viewport, so it moved with the
    /// device, the rotation, and Split View, and a smaller iPad reached barely
    /// half the detail a larger one did on the same document. Now one device
    /// pixel represents `zoomCapPagePointsPerPixel` page points at maximum zoom,
    /// on every device (A9).
    ///
    /// KNOWN DEFECT: zoom lives per page and dies with the controller. A page
    /// retired from the live window is released with no zoom saved, so turning
    /// back rebuilds it at fit-page, while pages still inside the window keep
    /// their scale — inconsistent by distance rather than uniformly wrong. The
    /// tool picker is shared across pages for exactly this reason; zoom is not.
    /// Whether zoom *should* be shared is a feel question, and Phillip's. Mixed
    /// geometry sharpens it: a shared *scale* across pages of different sizes
    /// would mean a turn changes how much of the page you can see.
    private func establishZoomIfNeeded() {
        let bounds = canvasView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds != zoomRangeBounds else { return }

        let fitWidth = bounds.width / geometry.width
        guard fitWidth > 0, fitWidth.isFinite else { return }
        let fitPage = min(fitWidth, bounds.height / geometry.height)
        guard fitPage > 0, fitPage.isFinite else { return }

        let previousFitPage = zoomRangeBounds.map {
            min($0.width / geometry.width, $0.height / geometry.height)
        }
        let ratio = previousFitPage.map { canvasView.zoomScale / $0 } ?? 1

        let displayScale = Double(max(traitCollection.displayScale, 1))
        let required = projection.maximumZoomScale(displayScale: displayScale)

        // The durable cap is validated against `minimumSupportedDisplayScale`
        // (2x — every iPad), so on supported hardware `required` never exceeds
        // what PKCanvasView delivers and the read-back precondition below
        // still traps on any real violation of that promise. A coarser
        // display — a trait collection not yet attached, or a 1x external
        // screen — asks for a scale the canvas silently refuses, and that is
        // not the document's promise breaking; it is hardware outside the
        // promise. RULE: below the minimum supported display scale the
        // ceiling clamps to `runtimeMaximumZoomScale`, loudly. Clamping is
        // otherwise forbidden (`Contract.md` — Invalid states fail loud),
        // which is why this clamp is confined to display scales no supported
        // iPad has: the alternative is crashing the app for plugging in a
        // monitor. The document's detail promise is unchanged and honored in
        // full the moment the page is back on 2x glass.
        let ceiling: Double
        if displayScale < PageProjection.minimumSupportedDisplayScale,
           required > PageProjection.runtimeMaximumZoomScale {
            ceiling = PageProjection.runtimeMaximumZoomScale
            CanvasLog.event(
                .canvas,
                "zoom ceiling clamped: display scale \(displayScale) is below the supported "
                    + "minimum \(PageProjection.minimumSupportedDisplayScale); the cap of "
                    + "\(projection.zoomCapPagePointsPerPixel) page points per pixel asks for "
                    + "scale \(required) and the canvas delivers \(ceiling)"
            )
        } else {
            ceiling = required
        }
        // A page so narrow that fitting its width already exceeds the deepest
        // zoom the document allows. It is an invalid state rather than a range
        // to reorder: the page would open above its own ceiling, and both the
        // floor and the cap would be describing something that is not a page.
        //
        // This traps — it crashes the app, it does not refuse the page. That is
        // deliberate and it is not the guard. The guard is upstream:
        // `EditorSession.importPDF` refuses a source box below
        // `PageProjection.smallestDisplayablePagePoints` before anything is
        // written, so no such page ever reaches a canvas. What is left here is
        // the assertion of that invariant at the one place it could be observed
        // failing, and a trap is the right shape for an invariant somebody else
        // upholds: by the time a page this small is being laid out, it is
        // already durable, and continuing would mean the page opens above its
        // own ceiling rather than merely failing to import.
        //
        // What is left open is a page already on disk: a document written
        // before the import guard existed, or edited outside this build, can
        // still carry one, and whether that should crash the document or be
        // refused the way unreadable bytes are is the error taxonomy's
        // question, not this trap's.
        precondition(
            CGFloat(ceiling) >= fitWidth,
            "page \(geometry.width)x\(geometry.height) is smaller than the "
                + "document's zoom cap allows: its fit-width scale "
                + "\(fitWidth) is past the ceiling \(ceiling)"
        )

        // Order matters: the range must admit the new scale before it is set,
        // or UIScrollView clamps it to the range still describing the old
        // viewport.
        canvasView.minimumZoomScale = fitPage
        canvasView.maximumZoomScale = CGFloat(ceiling)
        // `PKCanvasView` silently clamps `maximumZoomScale` to 10 — measured,
        // undocumented, and invisible unless something reads the value back.
        // A document that pinned a deeper cap would promise a detail level the
        // canvas quietly does not deliver, which is precisely the clamped
        // invalid state the contract refuses. So it is read back and trapped
        // here, at the one place that can see it happen.
        precondition(
            abs(Double(canvasView.maximumZoomScale) - ceiling) < 1e-6,
            "this document's zoom cap of \(projection.zoomCapPagePointsPerPixel) page "
                + "points per pixel asks for a maximum zoom scale of \(ceiling), and "
                + "PKCanvasView accepted \(canvasView.maximumZoomScale); it refuses "
                + "anything above \(PageProjection.runtimeMaximumZoomScale)"
        )
        canvasView.zoomScale = min(
            max(fitPage * ratio, canvasView.minimumZoomScale),
            canvasView.maximumZoomScale
        )
        zoomRangeBounds = bounds
        updatePageBoundary()
    }

    /// Keeps the page centred once it is smaller than the viewport.
    ///
    /// Both terms earn their keep now that the floor is fit-page: below
    /// fit-width — reachable in a landscape viewport — the side room splits
    /// evenly instead of pinning the page to the leading edge, and the
    /// vertical term does the same for a page shorter than the viewport.
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

    // MARK: - Static layers, beneath the ink

    /// Sets what this page carries below its ink.
    ///
    /// Told, never asked (`Contract.md` — Owners, golden rule 7): the list
    /// belongs to `EditorSession` and arrives by way of
    /// `PagedCanvasController`, exactly as the drawing and the shape tool do.
    /// The page's identity does not travel with it — the renderer keys on layer
    /// IDs, so this controller stays blind to which page it is.
    ///
    /// An empty list is the case that must cost nothing, and it does: no
    /// backdrop object exists, no layer is installed, and the canvas stays
    /// opaque. **The transparency the stack needs is paid for per page that has
    /// a stack**, not once and forever for the whole app — which is a real
    /// narrowing of the fork doc's "the ink surface goes transparent, and a
    /// full-screen blend under the ink is the floor cost everywhere, forever".
    /// Every page in a blank notebook is untouched by this feature.
    func setStaticLayers(_ layers: [LayerEnvelope]) {
        guard layers != staticLayers else { return }
        staticLayers = layers
        renderedRequest = nil
        compositeGeneration += 1
        // Whatever is decoding is decoding a list this page no longer has.
        compositeTask?.cancel()
        // A lens rendered from the old list is a picture of a page that no
        // longer exists.
        invalidateLens()

        guard !layers.isEmpty else {
            backdrop?.remove()
            backdrop = nil
            selection?.remove()
            selection = nil
            liftedLayerID = nil
            pendingLift = nil
            // Back to the cheap path: an opaque canvas is one fewer full-screen
            // blend per frame, and its background is the paper again.
            if isViewLoaded {
                canvasView.backgroundColor = .white
                canvasView.isOpaque = true
            }
            return
        }

        guard isViewLoaded else { return }
        installBackdropIfNeeded()
        installSelectionIfNeeded()
        selection?.setLayers(layers)
        requestCompositeIfNeeded()
    }

    /// Builds the selection runtime the first time this page carries something
    /// a tap can address, and never for a page that carries nothing.
    ///
    /// The same shape as `installBackdropIfNeeded`, and for the same reason:
    /// **the cost of this feature is paid per page that has a stack**, not once
    /// for the app. A blank page has no gesture recognizer of ours at all,
    /// which is the fork doc's "zero new gesture cost on the blank-page path"
    /// as a property of the object graph rather than of a code path.
    private func installSelectionIfNeeded() {
        guard selection == nil, staticLayers.contains(where: \.isSelectable) else { return }
        let installed = LayerSelectionRuntime(canvasView: canvasView, geometry: geometry)
        installed.onSelectionChanged = { [weak self] in
            self?.selectionChanged()
        }
        installed.onTransformPreview = { [weak self] transform in
            // One frame of a drag: a single transform assignment on one layer.
            // Nothing is published, nothing is saved, nothing is decoded.
            //
            // Only while the lift draws the selected layer: during an A→B
            // handover the lift still shows A, and moving it with B's
            // transform would drag the wrong picture.
            guard let self, self.liftedLayerID == self.selection?.selectedLayerID else { return }
            self.backdrop?.moveLift(to: transform)
        }
        installed.onTransformCommitted = { [weak self] layerID, previous, committed in
            self?.commitLayerTransform(layerID, from: previous, to: committed) ?? true
        }
        selection = installed
    }

    /// A layer was selected or deselected.
    ///
    /// The ordering here is the whole no-ghosting story, and it is one step
    /// more careful than the fork doc's:
    ///
    /// - **On selection**, the layer's own source is decoded first. Only once
    ///   it is on screen — drawn live above the composite it is still baked
    ///   into, which is one layer of overdraw and never a double image — is the
    ///   minus-one composite asked for. The fork doc has selection kick off the
    ///   recomposite immediately, which has a window in which the composite has
    ///   dropped the layer and nothing has picked it up: the layer *vanishes*.
    ///   Until the decode lands, nothing has changed at all.
    /// - **On deselection**, the full composite is asked for while the lift is
    ///   still up, and the lift is dropped only when that composite lands
    ///   (`requestCompositeIfNeeded`'s completion). There is no frame in which
    ///   the layer is in neither place.
    private func selectionChanged() {
        // The lift machinery owns the picture while a selection exists, and
        // the minus-one composite it triggers would leave a lens showing the
        // layer twice. `requestLensIfNeeded` also declines while selected.
        invalidateLens()
        liftGeneration += 1
        let generation = liftGeneration
        // The previous selection's decode is for a layer nothing will lift.
        liftTask?.cancel()
        // Whatever swap was queued is for a selection that no longer exists.
        pendingLift = nil

        guard let selected = selection?.selectedLayer,
              let staticRenderer,
              let scale = compositeScale()
        else {
            // Deselected. Ask for the whole stack again; the lift folds back
            // when it lands.
            requestCompositeIfNeeded()
            return
        }

        liftTask = Task { [weak self] in
            let image = await staticRenderer.sourceImage(for: selected, at: scale)
            // Cancellation first, because a cancelled decode answers `nil` and
            // `nil` otherwise means "this layer cannot be lifted" — a sentence
            // that would be logged about a selection nobody made.
            guard !Task.isCancelled, let self, self.liftGeneration == generation else { return }
            guard let image else {
                // Nothing can draw this layer live, so nothing may take it out
                // of the composite. Selection still works; the drag would move
                // chrome over a picture that does not follow, which is the
                // honest degradation and is unreachable in practice — the page
                // is on screen, so its asset already decoded once.
                CanvasLog.event(
                    .canvas,
                    "layer \(selected.layerID) selected but could not be lifted; "
                        + "it stays in the composite"
                )
                if self.liftedLayerID != nil {
                    // A previous layer's lift is still up but no longer
                    // matches the selection; fold it back into the full
                    // composite (the completion drops it once that lands).
                    self.requestCompositeIfNeeded()
                }
                return
            }
            if self.backdrop?.hasLift == true, self.liftedLayerID != selected.layerID {
                // Switching A→B: the composite on screen excludes A and only
                // the lift draws it. Hold A's lift until the composite that
                // re-includes A lands, and swap to B in the same main-actor
                // stretch that shows it — no frame in which either layer is
                // unrepresented.
                self.pendingLift = (image, selected)
                self.requestCompositeIfNeeded()
            } else {
                self.backdrop?.showLift(image, at: selected.pageSpaceTransform)
                self.liftedLayerID = selected.layerID
                self.requestCompositeIfNeeded()
            }
        }
    }

    /// The layers the composite draws: every static layer, minus the one being
    /// manipulated once something else is drawing it.
    ///
    /// Excluding a layer needs no new mechanism, which is the point: a
    /// `StaticLayerRequest` with one fewer layer is a different
    /// `CompositeKey` — the key is the list of layer IDs — so the minus-one
    /// composite is an ordinary second cache entry. It is also *stable* under
    /// the drag: moving the selected layer changes nothing about the request
    /// that excludes it, so a whole gesture, and every commit inside it, causes
    /// exactly zero re-composites.
    private var layersToComposite: [LayerEnvelope] {
        // The selected layer leaves the composite only once something else
        // draws it — the lift already showing it, or the pending swap that
        // will show it synchronously with this composite landing. A lift left
        // over from a *previous* selection excludes nothing.
        guard let selected = selection?.selectedLayerID,
              liftedLayerID == selected || pendingLift?.layer.layerID == selected
        else {
            return staticLayers
        }
        return staticLayers.filter { $0.layerID != selected }
    }

    /// Builds the sibling stack and makes the ink surface transparent so it
    /// shows through.
    ///
    /// The root view takes the page white the canvas used to paint, so the area
    /// outside the page looks exactly as it does today and the boundary
    /// hairline still has something to divide.
    private func installBackdropIfNeeded() {
        guard backdrop == nil else { return }
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // The backdrop paints its own paper at the page rect; the view behind
        // everything shows the same dark the margin strips show, so the
        // gutter is one colour with or without a stack.
        view.backgroundColor = .systemGray5
        let installed = PageBackdrop(under: canvasView, in: view, geometry: geometry)
        installed.viewportChanged(to: view.bounds)
        installed.mirror(offset: canvasView.contentOffset, zoom: canvasView.zoomScale)
        backdrop = installed
    }

    /// Asks for this page's composite at the current level of detail, unless
    /// that exact composite is already asked for.
    ///
    /// Reached from layout and from a layer edit — **never from a gesture
    /// frame**. A pinch shows the texture this produced, scaled and slightly
    /// soft; it triggers no decode, which is the rule the whole zoom story
    /// rests on.
    private func requestCompositeIfNeeded() {
        guard let backdrop, let staticRenderer, !staticLayers.isEmpty else { return }
        guard let scale = compositeScale() else { return }

        // `layersToComposite` rather than `staticLayers`: a selected layer is
        // lifted out of the composite it is being dragged from (phase 4's
        // minus-one). `geometry` is the page's own, not the canonical one, so
        // a landscape page composites at its own extent (phase 3b).
        let request = StaticLayerRequest(
            pageID: pageID,
            layers: layersToComposite,
            geometry: geometry,
            pixelsPerPagePoint: scale
        )
        guard request != renderedRequest else { return }
        renderedRequest = request

        // A new base request means the layers or the level of detail moved
        // under the lens; whatever it shows describes the old picture.
        invalidateLens()

        compositeGeneration += 1
        let generation = compositeGeneration
        // After the `request != renderedRequest` guard above, so re-asking for
        // the composite already in flight never cancels it — only a genuinely
        // different request does.
        compositeTask?.cancel()
        backdrop.compositeRequested()

        // One task per composite, at page-build and viewport frequency — not
        // per input sample, which is what `Contract.md` — Performance forbids.
        // Nothing is decoded here; the main thread's whole share of this
        // pipeline is the `contents` assignment inside `show`.
        compositeTask = Task { [weak self] in
            let render = await staticRenderer.composite(for: request)
            guard !Task.isCancelled, let self, self.compositeGeneration == generation else { return }
            self.backdrop?.show(render)
            if let pending = self.pendingLift {
                // The A→B swap: this composite re-includes the previously
                // lifted layer, so replacing the lift here — in the same
                // main-actor stretch, before any frame renders — leaves no
                // moment in which either layer is unrepresented.
                self.pendingLift = nil
                self.backdrop?.showLift(pending.image, at: pending.layer.pageSpaceTransform)
                self.liftedLayerID = pending.layer.layerID
            } else if self.selection?.selectedLayerID != self.liftedLayerID {
                // The fold-back, and the one moment it is safe: this composite
                // contains the lifted layer, so the lift is now a second copy
                // of something already drawn — dropping it changes no pixel.
                // Reached on deselection and when a lift outlived its
                // selection (a switch whose new layer could not be decoded).
                self.backdrop?.hideLift()
                self.liftedLayerID = nil
            }
        }
    }

    /// Composite pixels per page point: fit-width times the display scale,
    /// capped.
    ///
    /// Fit-width and **not** the live zoom, deliberately. Deriving detail from
    /// `zoomScale` would put a decode behind every pinch, which the contract's
    /// interaction-path rule forbids and which no PDF viewer on iOS does
    /// either. Rotation and Split View change this because they change
    /// fit-width; a gesture does not.
    ///
    /// Quantized to a hundredth so that a sub-pixel layout difference is not a
    /// whole new composite.
    private func compositeScale() -> Double? {
        Self.compositeDetail(
            viewportWidth: canvasView.bounds.width,
            displayScale: traitCollection.displayScale,
            geometry: geometry
        )
    }

    /// The one derivation of a page's base level of detail, `static` so the
    /// prefetch warm can reproduce it exactly: a warmed composite is a cache
    /// hit only if its request — including this number — is byte-for-byte the
    /// request this controller will make when the page turns live. Two copies
    /// of this arithmetic would be two numbers that drift, and a drifted warm
    /// is a cache that never hits while looking like it works.
    package static func compositeDetail(
        viewportWidth: CGFloat,
        displayScale: CGFloat,
        geometry: PageGeometry
    ) -> Double? {
        guard viewportWidth > 0 else { return nil }
        let clampedDisplayScale = max(displayScale, 1)
        let fitWidth = viewportWidth / geometry.width
        // The page's own long edge, so a landscape page is capped by its width
        // where a portrait one is capped by its height. Capping on a fixed axis
        // would let a wide page render past the texture budget the number
        // exists to state.
        let cap = Self.maximumCompositeLongEdge / max(geometry.width, geometry.height)
        let scale = min(max(Double(fitWidth * clampedDisplayScale), 1), cap)
        guard scale.isFinite, scale > 0 else { return nil }
        return (scale * 100).rounded() / 100
    }

    // MARK: - The lens: sharp content at zoom settle

    /// Whatever lens is on screen or in flight no longer describes the view.
    ///
    /// One integer increment and, when a lens is actually showing, one hidden
    /// flag — cheap enough for every scroll tick, which is where it runs: the
    /// moment the view transforms away from the settled state, the sharp
    /// patch must go, because a sharp patch at the wrong position is worse
    /// than the soft base underneath it.
    private func invalidateLens() {
        lensGeneration += 1
        // One `cancel` on a handle that is usually nil, next to the increment
        // that is already paid every scroll tick.
        lensTask?.cancel()
        lensTask = nil
        backdrop?.hideLens()
    }

    /// Asks for the visible rect at the settled zoom, off-main, and swaps it
    /// in above the base when it lands — the "at settle: background decode,
    /// then swap" moment of the fork doc's zoom story.
    ///
    /// Reached only from the scroll view's settle callbacks, **never from a
    /// gesture frame**: during the pinch the compositor scales the base,
    /// slightly soft, and no decode runs anywhere. Skipped when the settled
    /// zoom is not meaningfully past the base's own detail, when a selection
    /// is in progress (the lift machinery owns that picture), and on pages
    /// with nothing beneath their ink — the blank-page path pays one nil
    /// check.
    private func requestLensIfNeeded() {
        guard backdrop != nil, let staticRenderer, !staticLayers.isEmpty else { return }
        guard selection?.selectedLayerID == nil else { return }
        guard let base = renderedRequest?.pixelsPerPagePoint ?? compositeScale() else { return }

        let zoom = canvasView.zoomScale
        let bounds = canvasView.bounds
        guard zoom > 0, bounds.width > 0, bounds.height > 0 else { return }
        let displayScale = Double(max(traitCollection.displayScale, 1))
        // Quantized like the composite's own scale, so float dust in
        // `zoomScale` is not a new level of detail.
        let lensScale = (Double(zoom) * displayScale * 100).rounded() / 100
        guard lensScale > base * Self.lensWorthwhileFactor else { return }

        // The visible rect in page points, clamped to the page **before** the
        // renderer sees it: the rasterizer refuses out-of-page sub-rects, and
        // rightly — a rect past the edge is the caller's arithmetic to fix,
        // and this is that arithmetic. Rubber-band overshoot and centering
        // insets both put the raw rect outside the page routinely.
        let visible = CGRect(
            x: canvasView.contentOffset.x / zoom,
            y: canvasView.contentOffset.y / zoom,
            width: bounds.width / zoom,
            height: bounds.height / zoom
        )
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let clamped = visible.intersection(pageRect)
        guard !clamped.isEmpty else { return }

        let request = StaticLayerRequest(
            pageID: pageID,
            layers: layersToComposite,
            geometry: geometry,
            pixelsPerPagePoint: lensScale
        )
        lensGeneration += 1
        let generation = lensGeneration
        lensTask?.cancel()
        #if DEBUG
        lensRequestCountForTesting += 1
        lensRequestForTesting = (clamped, lensScale)
        #endif

        // One task per settle — settle frequency, never input frequency. The
        // render runs on the global executor; the main thread's whole share
        // is the `contents` assignment inside `showLens`.
        lensTask = Task { [weak self] in
            let render = await staticRenderer.lens(for: request, visibleRect: clamped)
            guard !Task.isCancelled, let self, self.lensGeneration == generation else { return }
            guard case .composited(let sharp) = render else {
                if case .refused(let why) = render {
                    // The base is still on screen and still honest — soft is
                    // an accepted state, so a lens refusal costs sharpness,
                    // never correctness.
                    CanvasLog.event(.canvas, "lens refused; the soft base stays: \(why)")
                }
                return
            }
            self.backdrop?.showLens(sharp.image, over: clamped)
        }
    }

    // MARK: - The shape tool

    /// Selects the shape a Pencil drag commits, or `nil` for freehand ink.
    ///
    /// The active tool belongs to `PagedCanvasController` (`Contract.md` —
    /// Owners), which is why this is told and never asked: every live page and
    /// every page built afterwards carries the same setting, so the tool
    /// survives a page turn exactly as the pen does.
    package func setShapeTool(_ kind: ShapeKind?) {
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

    // MARK: - Committing a layer transform

    /// The handover: one immutable committed value leaves the canvas runtime.
    ///
    /// This is the ink handover pattern verbatim (`Contract.md` — Owners,
    /// Navigation). Everything about a transform in progress — the selection,
    /// the grab, the per-frame value — stayed inside this runtime and reached
    /// no file and no SwiftUI observation. At the lift, one `PageSpaceTransform`
    /// crosses to `EditorSession`, which is the layer list's one writer, and
    /// the change follows the ordinary save path from there.
    ///
    /// Returns whether the session took it. A refusal is put back by the
    /// selection runtime rather than papered over: a picture that disagrees
    /// with the file is worse than a drag that visibly did not stick.
    ///
    /// ## Undo, and exactly what is and is not proven about it
    ///
    /// `Contract.proposed.md` A10: the inverse — the prior transform — is
    /// registered with **the responder chain's undo manager, PencilKit's own**,
    /// exactly once per commit. There is no second manager, nothing wraps or
    /// filters PencilKit's registrations, and undoing a layer edit re-emits the
    /// prior value through this same path, so it saves like any other edit.
    ///
    /// The registration comes **after** the session accepted, and the ordering
    /// is deliberately the opposite of `commit(_:)`'s. The shape tool registers
    /// first because it is about to mutate `canvasView.drawing`, and PencilKit
    /// may register an undo of its own for that assignment — registering first
    /// is what keeps the two in the right order. A layer transform touches no
    /// drawing at all, so there is no PencilKit registration to interleave
    /// with, and the only real hazard is the opposite one: an undo entry
    /// restoring a value the session refused to write. Asking first and
    /// registering only on acceptance means exactly one registration per
    /// committed edit and none per refusal, with nothing to unwind. The
    /// explicit group is kept regardless, so the entry is one Cmd-Z step.
    ///
    /// The target is `self`, and that is deliberate rather than incidental:
    /// `UndoManager` does not retain an action's target, and `willRetire`
    /// already calls `removeAllActions(withTarget: self)` before this
    /// controller is released. Registering against any other object would need
    /// a second retirement hook and would be a second way to leave a dangling
    /// target, which is a crash.
    ///
    /// **UNVERIFIED, and load-bearing for A10:** that PencilKit tolerates
    /// foreign registrations in its manager at all. No spike has run —
    /// `undoManager` walks the responder chain, so an unhosted controller
    /// reports `nil` and *none of this is testable off a device*
    /// (`Docs/Unproven.md` — Environment traps). If PencilKit ignores or drops
    /// foreign actions the failure is silent and benign: the layer edit is
    /// simply not undoable, the durable value is still correct, and nothing
    /// crashes. It is a device check, and it is on Phillip's list.
    ///
    /// KNOWN DEFECT: exactly as for the shape tool, a layer transform committed
    /// on a page that then leaves the live window is no longer undoable —
    /// `willRetire` drops the actions because their target is about to stop
    /// existing. Undo across a page turn is not a property this project claims
    /// (`Contract.md` — Navigation: turning is not undoable), and a dangling
    /// target is a crash, so the safe half is taken.
    @discardableResult
    func commitLayerTransform(
        _ layerID: UUID,
        from previous: PageSpaceTransform,
        to committed: PageSpaceTransform
    ) -> Bool {
        precondition(
            committed.isInvertible,
            "layer \(layerID) was committed with a singular transform, which is not placeable"
        )

        let accepted = host.layerTransformed(layerID, to: committed)
        guard accepted else {
            CanvasLog.event(.canvas, "layer \(layerID) transform refused by the session")
            return false
        }

        // No manager in the responder chain — an unhosted canvas, which in
        // practice means a test. The edit still landed; it is simply not
        // undoable, and nothing here fabricates a manager to hold an action
        // nobody can reach.
        guard let undoManager = canvasView.undoManager else { return true }

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { controller in
            // Not actor-isolated, and undo is invoked from the main thread by
            // the responder chain that reached it. Asserting that loudly is
            // better than hopping and losing the ordering.
            MainActor.assumeIsolated {
                // Recursive by construction: running this registers the
                // opposite move, which `UndoManager` files as the redo while it
                // is undoing. That is how a value-restoring undo stays undoable
                // and redoable indefinitely without a stack of its own.
                controller.commitLayerTransform(layerID, from: committed, to: previous)
            }
        }
        undoManager.endUndoGrouping()
        return true
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
        // Nothing this page has in flight can ever be installed again, so it
        // stops here. This is the flick: five pages of superseded decodes end
        // at the turn that superseded them rather than competing with the
        // Pencil on the page the user actually landed on
        // (`CONTRIBUTING.md` — Cancellation).
        //
        // Retirement is after the *handover*, which is synchronous by contract
        // and is not a task — there is no save or handover here to lose.
        compositeTask?.cancel()
        liftTask?.cancel()
        lensTask?.cancel()

        canvasView.undoManager?.removeAllActions(withTarget: self)
        // The selection is canvas-session state and dies with the canvas. It
        // also owns two recognizers on a view that is about to go, so leaving
        // it installed would leave them behind.
        selection?.remove()
        selection = nil
    }

    // MARK: - Drawing transfer

    /// Takes an independent drawing snapshot for later serialization.
    ///
    /// Copying the live drawing is the only work performed on the main actor.
    /// The full `dataRepresentation()` traversal runs from the snapshot's
    /// utility task, after the debounce, never from PencilKit's callback.
    package func drawingSnapshot() -> DrawingSnapshot {
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
    package func markEditable() {
        isEditable = true
    }

    /// Installs a page's drawing, strictly before the canvas becomes editable.
    ///
    /// PencilKit reports this assignment as a drawing change — measured, and
    /// synchronously, see `PageCanvasControllerTests`. That report must not
    /// mark the document dirty, and exactly one mechanism prevents it: nothing
    /// is listening while the ink lands. The delegate is detached across the
    /// assignment and restored immediately after, in the two lines that make
    /// the assignment, where a reader of the assignment cannot miss it.
    ///
    /// It used to be the wiring order in `PagedCanvasController.makeCanvas`,
    /// which attached the change callback only after this ran. That mechanism
    /// died with the callback: a page canvas now reports to a host it is
    /// constructed with (`PageCanvasHost`), because a canvas that can exist
    /// unwired is a canvas whose ink can be edited and never saved. There is
    /// still exactly one mechanism, and it has the same known limit the
    /// ordering had — it assumes the report is synchronous, and would be
    /// silently inert if PencilKit ever delivered it later.
    ///
    /// Installing over a canvas the user can already draw on would overwrite
    /// live ink with an older load result, which `Contract.md` — Lifecycle
    /// forbids outright, so that ordering is a precondition rather than a
    /// comment. Nothing here decodes and nothing can throw — decoding saved
    /// bytes is the paging runtime's step, and bytes that refuse to decode
    /// never reach a canvas at all.
    func installDrawing(from snapshot: DrawingSnapshot) {
        precondition(
            !isEditable,
            "installDrawing must not run once the canvas is editable; "
                + "it would overwrite live ink with an older drawing"
        )
        canvasView.delegate = nil
        canvasView.drawing = snapshot.drawingValue
        canvasView.delegate = self
    }

    // MARK: - PKCanvasViewDelegate

    /// Reported for every drawing mutation, including the load-time install. The
    /// canvas does not classify them: `EditorSession` owns save policy and is the
    /// one place that decides a change is not user editing.
    package func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !hasLoggedFirstChange {
            hasLoggedFirstChange = true
            CanvasLog.event(
                .canvas,
                "first drawing change; strokes=\(canvasView.drawing.strokes.count)"
            )
        }
        host.drawingChanged()
    }

    /// Frame-frequency work, and it stays here inside the canvas runtime: a
    /// frame assignment on one view, no publication and no allocation.
    package func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // The view is transforming away from whatever state a lens described:
        // drop it before this frame renders. An integer bump and a nil check —
        // no decode is ever triggered by a gesture frame.
        invalidateLens()
        updatePageBoundary()
        centerPageInViewport()
        // Re-traces a shape preview at the new scale, and returns immediately
        // when no shape is being dragged — which is every zoom that is not also
        // a Pencil drag.
        shapeTool?.viewportChanged()
        // Re-traces the selection chrome at the new scale, and returns
        // immediately with nothing selected — which is every zoom on every page
        // the user is merely reading.
        selection?.viewportChanged()
        // After centering, so the mirror reads the settled offset for this
        // tick. One transform assignment, and nothing at all on a page with no
        // static layers — no composite is asked for here, at any zoom.
        backdrop?.mirror(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)
        // Reads what was just presented against what was just mirrored. Two
        // presentation reads and no allocation, and nothing at all until a first
        // pinch has handed the probe a zoom view.
        zoomProbe.sample(
            canvasView: canvasView,
            modelZoom: scrollView.zoomScale,
            modelOffset: scrollView.contentOffset
        )
    }

    /// The pan half of the mirror. One transform assignment per tick, or one
    /// nil check on a page with nothing beneath its ink.
    ///
    /// `PagedCanvasController` is the delegate of the *outer* paging scroll
    /// view, so this observes only this page's own canvas.
    package func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Same rule as the zoom half: a pan moves the viewport off the rect
        // the lens was rendered for.
        invalidateLens()
        backdrop?.mirror(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)
    }

    // MARK: The settle callbacks — where the lens is asked for

    package func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        requestLensIfNeeded()
        // The scroll view hands over its own zooming view here, which is how the
        // probe reaches it without touching PencilKit's hierarchy.
        zoomProbe.adopt(view)
        zoomProbe.flush("pinch ended", canvasView: canvasView)
    }

    package func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A pan at depth settles too: without this, panning across a zoomed
        // worksheet would lose sharpness at the first tick and never regain
        // it until the next pinch.
        requestLensIfNeeded()
    }

    package func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate {
            requestLensIfNeeded()
        }
    }
}

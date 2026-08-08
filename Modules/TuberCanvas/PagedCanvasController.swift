import PencilKit
import TuberCore
import TuberModel
import TuberRender
import UIKit

/// Hosts an ordered run of pages and turns between them
/// (`Docs/Contract.md` — Navigation).
///
/// A horizontal paging `UIScrollView` holds one page-sized slot per page, but
/// only a small window of slots has a live view in it. The live count is
/// bounded by a constant and does not grow with the page count, which is what
/// `Contract.md` — Performance requires; a retired page's controller is
/// released, not parked for a possible return.
///
/// A slot inside the window is a canvas only when the session supplied the
/// page's ink. A page whose bytes are not held is a placeholder view — it
/// takes no input, so there is no stroke to drop when the bytes arrive and
/// none to misaccount at save time. An unloaded page is not a canvas.
///
/// Nesting is doing the hard work here, and it is deliberate. `PKCanvasView` is
/// itself a `UIScrollView` that owns pinch-zoom and in-page panning. A nested
/// scroll view chains to its parent once it can scroll no further in a
/// direction, so at fit-width scale — where a page cannot pan horizontally at
/// all — a horizontal drag reaches this scroll view and turns the page, and
/// zoomed in it pans within the page until it hits the page's own edge. That is
/// exactly the rule `Contract.md` — Navigation commits to, obtained from the
/// framework rather than from gesture recognizers of ours.
@MainActor
package final class PagedCanvasController: UIViewController, UIScrollViewDelegate {
    /// How many pages either side of the visible one stay live.
    ///
    /// **Two**, raised from one on Phillip's device verdict (2026-08-07): one
    /// prepared neighbour is enough for a deliberate turn, but a *flick* crosses
    /// two slots before anything settles, and the second one was still a
    /// placeholder when it came under the finger. The window is what the eye
    /// sees; the session's own prefetch radius — bytes and warmed composites —
    /// stays one wider than this, so a page entering the window still finds its
    /// bytes already here.
    ///
    /// This is a memory decision as much as a feel one: five live
    /// `PKCanvasView`s and five backdrops rather than three. It stays a
    /// constant, and that is the part `Contract.md` — Performance actually
    /// requires — the live count must not grow with the page count, which is
    /// what `PagedCanvasControllerTests` asserts. Raising a constant is a feel
    /// trade; making it a function of the document would be the defect.
    private static let windowRadius = 2

    let scrollView = UIScrollView()

    /// The page the user is looking at. `EditorSession` owns the durable current
    /// index; this is the runtime's view of it.
    private(set) var currentPageIndex = 0
    private(set) var pageCount = 1

    /// Everything this runtime cannot answer for itself, and everything it
    /// reports. Non-optional and supplied at construction, so an unwired seam
    /// is a compile error rather than a page that fails open — see
    /// `PagedCanvasSession`, which also states why this reference is strong.
    private let session: any PagedCanvasSession

    package enum PageContent {
        case blank
        case ink(Data)
        /// Unsaved ink the session holds for this page. It outranks anything
        /// on disk because it is newer by construction.
        case retained(DrawingSnapshot)
        /// Bytes requested and not yet arrived. Rendered as a placeholder;
        /// rebuilt by `reloadPage(at:)` once the bytes land.
        case loading
        /// Bytes that could not be read. Rendered as a refusal that says so
        /// (`Contract.md` — Invalid states fail loud).
        case unreadable(String)
    }

    /// One page's link back to the runtime that placed it.
    ///
    /// It exists to do two things a `PageCanvasController` must not do itself:
    /// add the page index, which that controller is blind to
    /// (`Contract.md` — Owners, golden rule 7), and hold the runtime `unowned`
    /// so that a page owning its host does not close an ownership loop. The
    /// runtime owns the page, the page owns this, and this outlives nothing.
    ///
    /// The index is captured for the slot's life, exactly as the closures it
    /// replaces captured it: a slot's index does not change while the slot
    /// exists.
    private final class SlotHost: PageCanvasHost {
        private unowned let runtime: PagedCanvasController
        private let pageIndex: Int

        init(runtime: PagedCanvasController, pageIndex: Int) {
            self.runtime = runtime
            self.pageIndex = pageIndex
        }

        func drawingChanged() {
            runtime.session.drawingChanged(onPageAt: pageIndex)
        }

        func layerTransformed(_ layerID: UUID, to transform: PageSpaceTransform) -> Bool {
            runtime.session.layerTransformed(
                onPageAt: pageIndex,
                layerID: layerID,
                to: transform
            )
        }
    }

    /// The shared tool picker. One per editor session, not one per page, so the
    /// selected pen survives a page turn.
    private let toolPicker = PKToolPicker()

    /// What occupies one windowed slot: a live page canvas, or a placeholder
    /// for a page whose ink the session does not hold.
    private enum Slot {
        case canvas(PageCanvasController)
        case placeholder(UIView)

        @MainActor
        var view: UIView {
            switch self {
            case .canvas(let page): page.view
            case .placeholder(let view): view
            }
        }
    }

    /// Live slots by page index. Bounded by `windowRadius`.
    private var slots: [Int: Slot] = [:]

    private var isEditable = false
    private var hasSettledInitialPage = false

    /// The viewport width the slots were last laid out at, or `nil` before the
    /// first layout with a width. Held so a *change* in width is distinguishable
    /// from a re-layout at the same width — see `viewDidLayoutSubviews`.
    private var laidOutViewportWidth: CGFloat?

    /// The shape the Pencil draws, or `nil` for freehand ink.
    ///
    /// It lives here for the same reason the tool picker does: the active tool
    /// is this runtime's state (`Contract.md` — Owners), one setting for the
    /// document rather than one per page, so choosing "rectangle" and turning
    /// the page does not silently put the pen back in your hand.
    package private(set) var shapeTool: ShapeKind?

    /// Flattens a page's static layers off-main. Shared across every page the
    /// way the tool picker is, so one cache serves the whole live window.
    ///
    /// `nil` in a runtime built without one — every test that hosts this
    /// controller directly — in which case pages render exactly as they did
    /// before this feature existed.
    private let staticRenderer: StaticLayerRenderer?

    package init(
        session: any PagedCanvasSession,
        staticRenderer: StaticLayerRenderer? = nil
    ) {
        self.session = session
        self.staticRenderer = staticRenderer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagedCanvasController is created in code only")
    }

    package override func viewDidLoad() {
        super.viewDidLoad()

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // The page turn is horizontal only. Vertical panning belongs to the
        // canvas inside the page, and letting both scroll vertically would make
        // a diagonal drag ambiguous.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .systemGray5
        scrollView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Lays the slots out, and — the reason this is the viewport-change hook —
    /// re-centres the visible page whenever the viewport width changed.
    ///
    /// Every offset in this runtime is `bounds.width × index`, so a width change
    /// invalidates the standing `contentOffset`. Left alone, a resize shows the
    /// wrong page immediately and then writes one durably: the user's next
    /// settle divides the stale offset by the new width, rounds, and reports a
    /// page the user never turned to — and `EditorSession` writes that index.
    /// A resize is not a page turn, so nothing here reports one; the offset is
    /// simply restated for the page that was already current.
    ///
    /// This hook rather than `viewWillTransition(to:with:)` or a trait
    /// observation: rotation is pinned to portrait and multi-scene is off
    /// (`project.yml`), so the live routes are Split View and Slide Over
    /// resizes, which change bounds without necessarily changing a trait and
    /// without a transition coordinator. Bounds are what the arithmetic
    /// actually depends on, and this is where bounds arrive.
    ///
    /// The offset is restated from `currentPageIndex` rather than scaled from
    /// the standing offset by the width ratio, which at rest is the same number
    /// and under a *widening* viewport is not: `UIScrollView` clamps
    /// `contentOffset` against the still-old `contentSize` before this runs, so
    /// the offset read here has already lost the last page's position. The
    /// index has not.
    package override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0 else { return }

        let previousWidth = laidOutViewportWidth
        laidOutViewportWidth = width

        updateContentSize()
        layoutSlots()

        if !hasSettledInitialPage {
            hasSettledInitialPage = true
            scrollTo(page: currentPageIndex, animated: false)
            refreshWindow()
            livePage(at: currentPageIndex)?.becomeActivePage()
        } else if let previousWidth, previousWidth != width {
            // A non-animated programmatic set fires no settle callback, so this
            // cannot be mistaken for a turn — and there is none to report.
            scrollTo(page: currentPageIndex, animated: false)
        }
    }

    // MARK: - Page set

    /// Sets the run of pages and which one is visible. Called by
    /// `EditorSession`, which owns page order and identity.
    ///
    /// This scrolls with `animated: false`, and UIKit fires no delegate
    /// callback for that — so this path performs the settle work itself,
    /// directly. Waiting on a settle callback here would mean the page never
    /// becomes editable after launch or append.
    package func setPages(count: Int, currentPageIndex index: Int) {
        precondition(count > 0, "a document always has at least one page")
        precondition(
            (0..<count).contains(index),
            "current page index must address an existing page"
        )

        let countChanged = count != pageCount
        pageCount = count
        currentPageIndex = index

        guard isViewLoaded, scrollView.bounds.width > 0 else { return }
        if countChanged { updateContentSize() }
        scrollTo(page: index, animated: false)
        refreshWindow()
        livePage(at: index)?.becomeActivePage()
    }

    /// Opens every live canvas for editing, and every later one as it is built.
    /// A placeholder has nothing to open: a page's canvas only exists at all
    /// once its ink was supplied.
    package func markEditable() {
        isEditable = true
        for case .canvas(let page) in slots.values {
            page.markEditable()
        }
    }

    /// Selects the shape a Pencil drag commits on every page, live or later.
    ///
    /// An intention from the SwiftUI root by way of `EditorSession`; nothing
    /// about it is durable, and no page's ink changes here.
    package func setShapeTool(_ kind: ShapeKind?) {
        shapeTool = kind
        for case .canvas(let page) in slots.values {
            page.setShapeTool(kind)
        }
    }

    /// Rebuilds a placeholder slot whose page changed underneath it — its
    /// bytes arrived, or its load failed with a reason to show.
    ///
    /// Legal only for a placeholder, by guard rather than by caller
    /// discipline: a canvas slot holds ink, and replacing it from loaded
    /// bytes would destroy anything drawn since — exactly the overwrite
    /// `Contract.md` — Lifecycle forbids. A canvas is replaced only by
    /// retirement.
    package func reloadPage(at index: Int) {
        guard case .placeholder(let stale)? = slots[index] else { return }
        stale.removeFromSuperview()
        slots[index] = makeSlot(at: index)
        layoutSlots()
        if index == currentPageIndex { livePage(at: index)?.becomeActivePage() }
    }

    /// Re-reads what sits beneath a live page's ink, after its layer list
    /// changed — an import, a deletion.
    ///
    /// Deliberately not `reloadPage(at:)`: that rebuilds the slot from loaded
    /// bytes, which for a canvas would destroy anything drawn since. A layer
    /// edit changes what is under the ink and must not touch the ink, so this
    /// tells the existing canvas and rebuilds nothing.
    ///
    /// A placeholder slot has no backdrop to refresh; a page whose refusal was
    /// just repaired becomes a canvas through `reloadPage(at:)` instead, which
    /// asks for the layer list as it builds.
    package func reloadStaticLayers(at index: Int) {
        livePage(at: index)?.setStaticLayers(session.staticLayers(forPageAt: index))
    }

    /// The live page controller for an index, if that slot is a canvas.
    /// Read by `snapshot(at:)` — which is how the save path reaches a live
    /// drawing — and by tests via `EditorSession.currentCanvas`.
    package func livePage(at index: Int) -> PageCanvasController? {
        guard case .canvas(let page)? = slots[index] else { return nil }
        return page
    }

    /// Read only by tests: it exists so that `Contract.md` — Performance's
    /// bound on the live canvas count is observable, and
    /// `PagedCanvasControllerTests` is what observes it — it must not grow
    /// with `pageCount`.
    var liveCanvasCount: Int {
        slots.values.reduce(into: 0) { count, slot in
            if case .canvas = slot { count += 1 }
        }
    }

    /// The base level of detail a canvas built for this page would ask its
    /// composite at, or `nil` before layout has given the slots a width.
    ///
    /// Read by `EditorSession`'s prefetch warm (phase 3c): a warmed composite
    /// only hits the cache if its request carries exactly the number the
    /// page's own controller will derive, and this runtime is the one place
    /// outside that controller that knows the slot width — a slot is one
    /// viewport wide, and the canvas fills its slot, so the viewport width
    /// *is* the future canvas's width.
    package func compositeDetail(forPageAt index: Int) -> Double? {
        guard isViewLoaded, scrollView.bounds.width > 0 else { return nil }
        return PageCanvasController.compositeDetail(
            viewportWidth: scrollView.bounds.width,
            displayScale: traitCollection.displayScale,
            geometry: session.projection(forPageAt: index).geometry
        )
    }

    /// A snapshot of one live page, or `nil` when the page has no canvas —
    /// outside the window, or a placeholder. A placeholder accepts no input,
    /// so `nil` here never discards ink; it only ever means there is none.
    package func snapshot(at index: Int) -> DrawingSnapshot? {
        livePage(at: index)?.drawingSnapshot()
    }

    // MARK: - Windowing

    /// ## Mixed geometry, and why a slot is still one viewport wide
    ///
    /// Geometry is per page since phase 3b, and mixed geometry is the normal
    /// state of an annotated import rather than an edge case: swiping past the
    /// last page of a landscape PDF appends a blank *canonical portrait* page.
    /// So the arithmetic below has to be a decision rather than an assumption,
    /// and the decision is: **a slot is one viewport wide, always, whatever the
    /// page in it measures. The page varies inside its slot, not the slot.**
    ///
    /// A page canvas fills its slot and fits its own page inside itself — its
    /// zoom floor and its opening fit-width scale come from its own geometry,
    /// and `PageCanvasController.centerPageInViewport` centres what is left
    /// over. A landscape page therefore opens at its own fit-width and leaves
    /// room above and below; a portrait page beside it opens at a different
    /// scale and fills more of the height. Neighbours never bleed into the
    /// slot: nothing is ever partly visible, so nothing has to be decided about
    /// how two differently sized pages sit against each other.
    ///
    /// The alternative — a slot as wide as its page, so the run of pages is a
    /// filmstrip of true relative sizes — was rejected, and the price is worth
    /// stating because it is not small:
    ///
    /// - `isPagingEnabled` snaps on multiples of the scroll view's *bounds*
    ///   width. Variable slots mean turning that off and re-deriving the snap
    ///   in `scrollViewWillEndDragging(targetContentOffset:)`. That is a
    ///   hand-written gesture arbitration replacing one obtained from the
    ///   framework — which is exactly what `Contract.md` — Navigation says it
    ///   takes from `UIScrollView` "rather than from gesture recognizers of
    ///   ours", and the rule that "there is no resting position between two
    ///   pages" would become ours to keep rather than the framework's.
    /// - Every offset here is `bounds.width × index`: `scrollTo`, `settle`'s
    ///   rounding, and the append trigger's "past the last page's trailing
    ///   edge". All three become prefix sums over page widths, and `settle`
    ///   becomes a search rather than a rounding.
    /// - It would also mean deciding a *scale*: a page's slot width in view
    ///   points is a rendering choice, not a durable fact, so a filmstrip has
    ///   to pick one points-per-page-point for the whole document and then
    ///   answer what happens when a page is wider than the viewport at it.
    ///
    /// None of that is bought by anything this milestone needs, and all of it
    /// is reversible: nothing durable and nothing in `PageCanvasController`
    /// assumes a uniform slot — only these three lines do.
    ///
    /// What is genuinely undecidable here is whether it *feels* right to turn
    /// from a portrait page to a landscape one and have the scale change under
    /// you. That is a maintainer's verdict on a physical iPad; `Docs/Unproven.md`
    /// carries it.
    private func updateContentSize() {
        scrollView.contentSize = CGSize(
            width: scrollView.bounds.width * CGFloat(pageCount),
            height: scrollView.bounds.height
        )
    }

    private func slotFrame(for index: Int) -> CGRect {
        CGRect(
            x: scrollView.bounds.width * CGFloat(index),
            y: 0,
            width: scrollView.bounds.width,
            height: scrollView.bounds.height
        )
    }

    private func scrollTo(page index: Int, animated: Bool) {
        scrollView.setContentOffset(
            CGPoint(x: scrollView.bounds.width * CGFloat(index), y: 0),
            animated: animated
        )
    }

    private var windowedIndices: Set<Int> {
        let lower = max(0, currentPageIndex - Self.windowRadius)
        let upper = min(pageCount - 1, currentPageIndex + Self.windowRadius)
        return Set(lower...upper)
    }

    /// Builds slots that entered the window and retires those that left.
    ///
    /// Retirement hands the ink to the session first and releases second. The
    /// order is the whole point: releasing first would discard edits made on a
    /// page the user simply scrolled away from. Every canvas hands over —
    /// a canvas only exists once its ink was supplied, so there is no
    /// unloaded-blank exception to carve out.
    private func refreshWindow() {
        let wanted = windowedIndices

        for (index, slot) in slots where !wanted.contains(index) {
            switch slot {
            case .canvas(let page):
                session.pageIsRetiring(at: index, handingOver: page.drawingSnapshot())
                // After the handover and before the release: the ink is safe,
                // and what goes now is only this page's undo actions, whose
                // target is about to stop existing.
                page.willRetire()
                page.willMove(toParent: nil)
                page.view.removeFromSuperview()
                page.removeFromParent()
            case .placeholder(let view):
                // Nothing to hand over: a placeholder holds no ink by
                // construction.
                view.removeFromSuperview()
            }
            slots[index] = nil
        }

        for index in wanted.sorted() where slots[index] == nil {
            slots[index] = makeSlot(at: index)
        }

        layoutSlots()
    }

    /// KNOWN DEFECT: this runs synchronously on main, reached from the settle
    /// callbacks via `refreshWindow`. It constructs the controller,
    /// forces `view` (and so `PKCanvasView` setup), and synchronously decodes
    /// ink via `PKDrawing(data:)`. Settling moved this off the drag itself —
    /// it no longer runs mid-gesture — but at rest it is still synchronous
    /// main-thread work. Unmeasured; a fast flick across several pages is the
    /// case to watch.
    private func makeSlot(at index: Int) -> Slot {
        switch session.canvasContent(forPageAt: index) {
        case .blank:
            return .canvas(makeCanvas(at: index, installing: nil))

        case .ink(let data):
            let drawing: PKDrawing
            do {
                drawing = try PKDrawing(data: data)
            } catch {
                // Bytes the session holds that nonetheless refuse to decode.
                // The same refusal as `.unreadable`, discovered one step
                // later: never an editable blank.
                CanvasLog.event(
                    .canvas,
                    "page \(index) drawing failed to decode: \(error)"
                )
                return .placeholder(makePlaceholder(saying: "This page could not be read."))
            }
            return .canvas(makeCanvas(at: index, installing: DrawingSnapshot(drawing: drawing)))

        case .retained(let snapshot):
            return .canvas(makeCanvas(at: index, installing: snapshot))

        case .loading:
            return .placeholder(makePlaceholder(saying: "This page is loading…"))

        case .unreadable(let message):
            return .placeholder(
                makePlaceholder(saying: "This page could not be read.\n\(message)")
            )
        }
    }

    private func makeCanvas(at index: Int, installing snapshot: DrawingSnapshot?) -> PageCanvasController {
        // The page reports through its host from the moment it exists: there is
        // no window in which a canvas is live and reporting nowhere. What used
        // to keep the install from being reported as an edit was the *absence*
        // of that wiring until after the install; the install now hides itself
        // instead, in `PageCanvasController.installDrawing`, which is where the
        // assignment is and where a reader looking for the rule will be.
        let page = PageCanvasController(
            toolPicker: toolPicker,
            projection: session.projection(forPageAt: index),
            host: SlotHost(runtime: self, pageIndex: index),
            staticRenderer: staticRenderer
        )

        addChild(page)
        page.view.frame = slotFrame(for: index)
        scrollView.addSubview(page.view)
        page.didMove(toParent: self)

        // Strictly before the page becomes editable, which is the ordering
        // `PageCanvasController.installDrawing` enforces by precondition.
        if let snapshot {
            page.installDrawing(from: snapshot)
        }

        // A page built while the shape tool is on draws shapes too. Applied
        // after the install, because nothing about the tool may participate in
        // loading a page's ink.
        page.setShapeTool(shapeTool)

        // What sits beneath the ink. After the install, for the same reason:
        // nothing about rendering the backdrop may participate in loading a
        // page's ink, and a composite arriving late must never be able to
        // reach the drawing.
        page.setStaticLayers(session.staticLayers(forPageAt: index))

        if isEditable { page.markEditable() }
        return page
    }

    /// A slot for a page that is not a canvas. Plain, inert, and honest about
    /// why: `Contract.md` — Invalid states fail loud. It participates in no
    /// touch handling, so nothing drawn here can exist to be lost.
    private func makePlaceholder(saying message: String) -> UIView {
        let placeholder = UIView()
        placeholder.backgroundColor = .systemGray6

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        placeholder.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: placeholder.leadingAnchor, constant: 24
            ),
        ])

        scrollView.addSubview(placeholder)
        return placeholder
    }

    private func layoutSlots() {
        for (index, slot) in slots {
            slot.view.frame = slotFrame(for: index)
        }
    }

    // MARK: - UIScrollViewDelegate

    /// Commits the turn the scroll view has come to rest on.
    ///
    /// Called only from the three settle callbacks and from the programmatic
    /// routes that scroll with `animated: false` — `setPages` and the initial
    /// layout — which fire no delegate callback at all and therefore settle
    /// themselves. Nothing turn-shaped happens per frame: a drag that merely
    /// crosses the halfway point mutates no durable state, steals no first
    /// responder, decodes no ink, and arms no save, because the user may yet
    /// abandon it. "There is no resting position between two pages"
    /// (`Contract.md` — Navigation) — so there is no turn before rest either.
    private func settle() {
        guard scrollView.bounds.width > 0, hasSettledInitialPage else { return }

        let settled = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        guard settled != currentPageIndex, (0..<pageCount).contains(settled) else { return }

        currentPageIndex = settled
        refreshWindow()
        livePage(at: settled)?.becomeActivePage()
        session.currentPageChanged(to: settled)
    }

    // The delegate callbacks below, and the `override`s above, are `package`
    // because Swift requires a member satisfying a protocol requirement — or
    // overriding one — to be as visible as its type, not because anything
    // outside this module calls them. Read the visibility of a *named* member
    // as a statement about the module boundary; read these as the language's.
    package func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    package func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag that ends past the last page's trailing edge is the append
    /// gesture. Reported, never acted on here: growing the document is the
    /// session's decision (`Contract.md` — Owners). An ordinary drag that ends
    /// without deceleration is already at rest, so it settles here.
    package func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard scrollView.bounds.width > 0 else { return }
        let lastPageOffset = scrollView.bounds.width * CGFloat(pageCount - 1)
        if scrollView.contentOffset.x > lastPageOffset + Self.appendTriggerFraction
            * scrollView.bounds.width {
            // The session's append drives `setPages`, which settles the new
            // page itself — synchronously, inside this call: the page count,
            // contentSize, the blank slot, and the offset all describe the new
            // page by the time the callback below returns.
            let countBeforeAppend = pageCount
            session.reachedEndBoundary()
            if pageCount > countBeforeAppend {
                // UIKit computed this gesture's deceleration target *before*
                // this delegate call, against the contentSize that still ended
                // at the old last page, and it arms that animation after we
                // return — overriding the offset `setPages` just wrote and
                // rubber-banding back to the old page, with the overscroll's
                // grey filling the screen while the two fight. An offset write
                // inside this callback cannot cancel an animation that has not
                // started yet, so the target is re-asserted on the next runloop
                // turn, where a programmatic setContentOffset reliably kills
                // the in-flight bounce. This re-asserts an offset for a page
                // the session already created; the runtime still never grows
                // the document, or the contentSize, by itself.
                let target = currentPageIndex
                // A task, not per-sample work: this runs once per append
                // gesture, at drag end (`Contract.md` — Performance).
                Task { [weak self] in
                    guard let self, self.currentPageIndex == target else { return }
                    // A programmatic non-animated set cancels the in-flight
                    // bounce; one tick in it has barely moved, so the
                    // correction is imperceptible next to the fight it
                    // prevents. It fires no delegate callback, and none is
                    // needed: setPages already committed this index, so no
                    // second turn can exist.
                    self.scrollView.setContentOffset(
                        CGPoint(x: self.scrollView.bounds.width * CGFloat(target), y: 0),
                        animated: false
                    )
                }
            }
            // The session refused the append (not ready): the ordinary
            // rubber-band returns to the last real page, and the settle it
            // fires there matches currentPageIndex — no turn.
            return
        }
        if !willDecelerate { settle() }
    }

    /// How far past the last page you must pull before it counts as asking for a
    /// new one. Generous enough that the rubber-band from an ordinary turn onto
    /// the last page does not trigger it.
    private static let appendTriggerFraction: CGFloat = 0.35
}

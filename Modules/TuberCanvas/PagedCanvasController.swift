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
/// A slot inside the window is a canvas only when the page's ink is *in it*.
/// A page whose bytes are not held, or are held and not yet decoded, is a
/// placeholder view — it takes no input, so there is no stroke to drop when
/// the ink arrives and none to misaccount at save time. An unloaded page is
/// not a canvas.
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

    /// The rendered order: the page identities this runtime lays out, in
    /// document order, exactly as the session last stated them
    /// (`setPages(_:current:)`). Told, never inferred, and never grown here —
    /// the runtime does not create pages (`Contract.md` — Owners).
    ///
    /// Empty until the session states an order. A runtime with no order lays
    /// out nothing and asks nothing, which is the honest picture of "this
    /// document has not been read yet": before, a bare runtime showed one slot
    /// for a page nobody had described, and the session answered it `.blank` —
    /// an editable blank canvas standing where a real page was about to load.
    private var order: [UUID] = []

    /// The page the user is looking at, by identity. `EditorSession` owns the
    /// durable current index; this is the runtime's view of it, and it survives
    /// a list change that would move the same page to a different position.
    private(set) var currentPageID: UUID?

    /// Where a page sits in the rendered order — **the one place identity
    /// becomes geometry**, and the only reason a position exists in this file
    /// at all. Every offset, frame, and content size is derived through here.
    ///
    /// A linear scan, deliberately: it runs at turn, layout, and list-mutation
    /// frequency — never per Pencil sample, per scroll tick, or per frame
    /// (`Contract.md` — Performance) — and a `[UUID: Int]` beside `order` would
    /// be a second copy of a fact `order` already states, to be kept in step
    /// with it. If a measurement ever says the scan matters, that dictionary is
    /// the fix, rebuilt in `setPages` and nowhere else.
    private func position(of pageID: UUID) -> Int? {
        order.firstIndex(of: pageID)
    }

    /// The visible page's position, or 0 before an order exists.
    ///
    /// Derived and read-only: `currentPageID` is the value, and this is where
    /// it becomes geometry. Nothing writes a *position* — a write would be a
    /// second authority over which page is current, and the whole point of the
    /// identity is that it survives the list changing under it.
    var currentPageIndex: Int { currentPageID.flatMap(position(of:)) ?? 0 }

    var pageCount: Int { order.count }

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
    /// add the page identity, which that controller is blind to
    /// (`Contract.md` — Owners, golden rule 7), and hold the runtime `unowned`
    /// so that a page owning its host does not close an ownership loop. The
    /// runtime owns the page, the page owns this, and this outlives nothing.
    ///
    /// **The identity is captured for the slot's life, and that is now sound
    /// rather than assumed.** It used to capture the page's *index*, on the
    /// stated assumption that a slot's index does not change while the slot
    /// exists — true only while pages were append-only. A delete or a reorder
    /// falsifies it for every surviving slot at once, and the failure is
    /// silent: the live canvas keeps reporting under an index that now names a
    /// different page, so a stroke dirties a page the user never touched and a
    /// retirement hands one page's ink into another page's custody. An identity
    /// is stable for the page's life, which is strictly longer than the slot's.
    private final class SlotHost: PageCanvasHost {
        private unowned let runtime: PagedCanvasController
        private let pageID: UUID

        init(runtime: PagedCanvasController, pageID: UUID) {
            self.runtime = runtime
            self.pageID = pageID
        }

        func drawingChanged() {
            runtime.session.drawingChanged(onPage: pageID)
        }

        func layerTransformed(_ layerID: UUID, to transform: PageSpaceTransform) -> Bool {
            runtime.session.layerTransformed(
                onPage: pageID,
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

    /// Live slots by page identity. Bounded by `windowRadius`.
    ///
    /// Keyed by identity for the reason `SlotHost` captures one: a slot holds a
    /// *page*, and after a delete or a reorder the page at a given position is
    /// a different page. Keyed by position, every surviving slot would show the
    /// wrong page and `refreshWindow` would keep it there.
    private var slots: [UUID: Slot] = [:]

    /// The page the append pull would create, standing in the overscroll room
    /// past the last slot — so pulling for a new page shows a page arriving,
    /// not grey void that pops into one (device verdict, 2026-08-08).
    ///
    /// A picture, not a page: the white page rect with its hairline on the
    /// gutter's dark, which since the universally-dark-margins verdict
    /// (2026-08-08, "it's neater") is exactly what a live slot shows around
    /// its page — so the seam between the last real page and the promised one
    /// is one continuous gutter. It lives in content space, so it scrolls for
    /// free and is repositioned only when the slots are — never per frame. It
    /// takes no input, holds no ink, and is not a slot: the runtime still
    /// never grows the document, and the commit is still the drag-end
    /// trigger. When the commit lands, the real canvas lays its paper over
    /// exactly this rect, which is what makes the release continuous instead
    /// of a pop.
    ///
    /// Always present past the end, visible only in overscroll. An ordinary
    /// turn's bounce onto the last page can flash its leading sliver; that
    /// sliver is a true statement — this is what pulling further gets you.
    /// The one lie it can tell is a session that refuses the append (not
    /// ready): the pull shows a page and the release rubber-bands it away.
    /// Rare, transient, and honest the moment the session can append again.
    private let appendPreview = UIView()

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

        appendPreview.backgroundColor = .white
        appendPreview.isUserInteractionEnabled = false
        appendPreview.layer.borderColor = UIColor.separator.cgColor
        scrollView.addSubview(appendPreview)

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
            currentPageID.flatMap(livePage)?.becomeActivePage()
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
    /// The order arrives as a whole snapshot rather than as a mutation, because
    /// the session is the one writer of it: this runtime never reasons about
    /// what changed, it renders what it is told.
    ///
    /// This scrolls with `animated: false`, and UIKit fires no delegate
    /// callback for that — so this path performs the settle work itself,
    /// directly. Waiting on a settle callback here would mean the page never
    /// becomes editable after launch or append.
    ///
    /// ## Reconciling a list that changed
    ///
    /// A page that is in the runtime and not in the new order has been
    /// **deleted**, and its live canvas is retired here — deliberately
    /// *without* the handover `refreshWindow` performs. The distinction is the
    /// whole of it: a page leaving the *window* is still a page of the
    /// document, so its unsaved ink must reach the session's custody or it
    /// dies with the canvas; a page leaving the *document* has been deleted by
    /// an act the user confirmed, and handing its ink over would resurrect it
    /// as custody for a page nothing will ever save — a session permanently
    /// dirty for a page it no longer has.
    ///
    /// What still runs for a departed page is `willRetire()`. It is not part
    /// of the handover: it cancels the page's in-flight render tasks, drops
    /// the undo actions whose target is about to stop existing, and removes
    /// the selection's two gesture recognizers from a view that is going away.
    /// Skipping it would leak a dangling undo target, which is a crash.
    ///
    /// Everything below completes **synchronously inside this call** — the
    /// property `scrollViewDidEndDragging`'s append correction depends on: by
    /// the time this returns, the order, the content size, the slots, and the
    /// offset all describe the new list.
    package func setPages(_ pageIDs: [UUID], current pageID: UUID) {
        precondition(!pageIDs.isEmpty, "a document always has at least one page")
        precondition(
            pageIDs.contains(pageID),
            "the current page must be one of the document's pages"
        )
        precondition(
            Set(pageIDs).count == pageIDs.count,
            "page identities are unique within a document"
        )

        // Before the order changes under them, and before `refreshWindow` can
        // see them: it retires by "not in the window", which for a deleted page
        // would take the handover path and hand a deleted page's ink into the
        // session's custody.
        let surviving = Set(pageIDs)
        for (departedID, slot) in slots where !surviving.contains(departedID) {
            slots[departedID] = nil
            retire(departedID, slot, handingOver: false)
        }
        // A decode in flight for a departed page is cancelled by `retire`
        // above, and needs no pass of its own: a decode is started only by
        // `makeSlot`, whose slot is always filed in `slots`, so every entry in
        // `pendingDecodes` has a slot and every departed slot is retired here.
        // A second sweep was written, and deleted for being unable to fail —
        // reverting `retire`'s cancellation left it green.

        let countChanged = pageIDs.count != order.count
        order = pageIDs
        currentPageID = pageID

        guard isViewLoaded, scrollView.bounds.width > 0 else { return }
        if countChanged { updateContentSize() }
        // The offset is restated for the current *page*, whose position may
        // have moved even when the count did not — a reorder, or a delete
        // before it. Non-animated, so no delegate callback fires and no settle
        // can mistake this for a turn the user made.
        scrollTo(page: currentPageIndex, animated: false)
        // Survivors are re-framed inside here, from their new positions: a
        // live canvas *moves*, it is never rebuilt, so no ink and no zoom
        // state is touched by a page being inserted ahead of it.
        refreshWindow()
        // Without this, deleting the page you are looking at leaves the
        // successor without first responder: the tool picker is dead and the
        // Pencil writes nowhere.
        livePage(pageID)?.becomeActivePage()
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
    package func reloadPage(_ pageID: UUID) {
        guard case .placeholder(let stale)? = slots[pageID] else { return }
        stale.removeFromSuperview()
        slots[pageID] = makeSlot(for: pageID)
        layoutSlots()
        if pageID == currentPageID { livePage(pageID)?.becomeActivePage() }
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
    package func reloadStaticLayers(onPage pageID: UUID) {
        livePage(pageID)?.setStaticLayers(session.staticLayers(forPage: pageID))
    }

    /// The live page controller for a page, if that slot is a canvas.
    /// Read by `snapshot(ofPage:)` — which is how the save path reaches a live
    /// drawing — and by tests via `EditorSession.currentCanvas`.
    package func livePage(_ pageID: UUID) -> PageCanvasController? {
        guard case .canvas(let page)? = slots[pageID] else { return nil }
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
    package func compositeDetail(forPage pageID: UUID) -> Double? {
        guard isViewLoaded, scrollView.bounds.width > 0 else { return nil }
        return PageCanvasController.compositeDetail(
            viewportWidth: scrollView.bounds.width,
            displayScale: traitCollection.displayScale,
            geometry: session.projection(forPage: pageID).geometry
        )
    }

    /// A snapshot of one live page, or `nil` when the page has no canvas —
    /// outside the window, or a placeholder. A placeholder accepts no input,
    /// so `nil` here never discards ink; it only ever means there is none.
    package func snapshot(ofPage pageID: UUID) -> DrawingSnapshot? {
        livePage(pageID)?.drawingSnapshot()
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
    /// zoom floor and its opening fit-page scale come from its own geometry,
    /// and `PageCanvasController.centerPageInViewport` centres what is left
    /// over. A landscape page therefore opens at its own fit and leaves
    /// room on the axis its shape does not fill; a portrait page beside it
    /// opens at a different scale. Neighbours never bleed into the
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
            width: scrollView.bounds.width * CGFloat(order.count),
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

    /// The pages that should have a live slot: the visible one and
    /// `windowRadius` either side, by identity.
    ///
    /// Empty before an order exists, which is what makes a runtime nobody has
    /// described lay out nothing at all.
    private var windowedPageIDs: Set<UUID> {
        guard let position = currentPageID.flatMap(position(of:)) else { return [] }
        let lower = max(0, position - Self.windowRadius)
        let upper = min(order.count - 1, position + Self.windowRadius)
        guard lower <= upper else { return [] }
        return Set(order[lower...upper])
    }

    /// Builds slots that entered the window and retires those that left.
    ///
    /// Retirement hands the ink to the session first and releases second. The
    /// order is the whole point: releasing first would discard edits made on a
    /// page the user simply scrolled away from. Every canvas hands over —
    /// a canvas only exists once its ink was supplied, so there is no
    /// unloaded-blank exception to carve out.
    private func refreshWindow() {
        let wanted = windowedPageIDs
        let position = currentPageIndex

        for (pageID, slot) in slots where !wanted.contains(pageID) {
            slots[pageID] = nil
            // A page leaving the window is still a page of the document, so
            // its ink must reach the session before its canvas is released.
            retire(pageID, slot, handingOver: true)
        }

        // Nearest the current page first. It was left to right, which starts
        // two pages behind the user. Now that each inked slot starts a decode
        // as it is built, build order is start order, and the page under the
        // finger should not be queued behind the two the user just left.
        let byDistance = wanted
            .compactMap { pageID in self.position(of: pageID).map { (pageID, $0) } }
            .sorted { abs($0.1 - position) < abs($1.1 - position) }
        for (pageID, _) in byDistance where slots[pageID] == nil {
            slots[pageID] = makeSlot(for: pageID)
        }

        layoutSlots()
    }

    /// Releases one slot, with or without handing its ink to the session.
    ///
    /// The caller has already removed the slot from `slots`: this owns the
    /// teardown, not the bookkeeping, so there is no moment at which a
    /// half-retired slot is reachable.
    ///
    /// **`handingOver` is the only difference between a page leaving the
    /// window and a page leaving the document**, and it is a parameter rather
    /// than two methods because everything else about the two is identical and
    /// must stay identical — the cancellation, the undo teardown, the
    /// parent/child unwind, and their order.
    private func retire(_ pageID: UUID, _ slot: Slot, handingOver: Bool) {
        // The page is leaving; a decode still running for it is work nobody
        // will install, competing with the Pencil for the CPU.
        cancelDecode(for: pageID)
        switch slot {
        case .canvas(let page):
            if handingOver {
                session.pageIsRetiring(pageID, handingOver: page.drawingSnapshot())
            }
            // After the handover and before the release: the ink is safe, and
            // what goes now is this page's in-flight renders, its undo actions
            // — whose target is about to stop existing — and its selection's
            // recognizers. None of it reports to the session, which is what
            // makes it safe to run for a page the session has already dropped.
            page.willRetire()
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
        case .placeholder(let view):
            // Nothing to hand over: a placeholder holds no ink by
            // construction.
            view.removeFromSuperview()
        }
    }

    /// Builds one slot. Still synchronous main-thread work — it constructs the
    /// controller and forces `view`, and so `PKCanvasView` setup — but no
    /// longer decodes ink: `PKDrawing(data:)` is the expensive half and it now
    /// runs off main (`decodeInk`).
    ///
    /// What the measurement said, on the pinned simulator, with the 20k-stroke
    /// / 4.64 MB page `SettleDecodeBenchmark` generates: **32 ms per decode**,
    /// and **219 ms for one settle** that brought five such pages into the
    /// window — thirteen frame budgets in a single main-thread turn. That is
    /// the hitch the fork document's rule names, so the decode moved. A
    /// simulator number bounds nothing about an iPad, and the device
    /// measurement is still owed (`Docs/Unproven.md`); what it can overturn is
    /// the *residual* — whether the construction left here is itself too much
    /// — not the decision to move the decode.
    private func makeSlot(for pageID: UUID) -> Slot {
        // Whatever this page was doing, it is not doing it any more. Every
        // rebuild of a slot funnels through here, so this is the one place
        // that has to remember to stop a decode nobody will install.
        cancelDecode(for: pageID)

        switch session.canvasContent(forPage: pageID) {
        case .blank:
            return .canvas(makeCanvas(for: pageID, installing: nil))

        case .ink(let data):
            // A placeholder, exactly as for `.loading` — and for the same
            // reason, which is the whole of this path's ink-integrity
            // argument. Bytes that have not been decoded are not in a canvas,
            // and a canvas that exists before they arrive is one the user can
            // draw on: its empty drawing would be handed to the save path over
            // the page's real ink, or its strokes dropped when the install
            // overwrote them. So the page stays a placeholder — no input, no
            // `livePage`, no snapshot — until the drawing is in it.
            return .placeholder(startDecoding(for: pageID, from: data))

        case .retained(let snapshot):
            return .canvas(makeCanvas(for: pageID, installing: snapshot))

        case .loading:
            return .placeholder(makePlaceholder(saying: "This page is loading…"))

        case .unreadable(let message):
            return .placeholder(
                makePlaceholder(saying: "This page could not be read.\n\(message)")
            )
        }
    }

    // MARK: - Decoding a page's ink off main

    /// A decode in flight for one slot, and the token that says which request
    /// it belongs to.
    ///
    /// Both halves of `CONTRIBUTING.md` — Cancellation are here, and they are
    /// needed for different failures. The **task** is cancelled the moment the
    /// slot stops wanting it — a page leaving the window, a rebuild — so a
    /// five-page flick does not run five superseded decodes to completion
    /// against the Pencil. The **token** is compared at the install site,
    /// because cancellation is asynchronous: a decode that finished just
    /// before the cancel landed is a completed drawing looking for somewhere
    /// to go, and the same page index can already be back in the window
    /// wanting different bytes. Cancel so the work stops; compare so what
    /// finished cannot install stale.
    private struct PendingDecode {
        let token: Int
        let task: Task<Void, Never>
    }

    private var pendingDecodes: [UUID: PendingDecode] = [:]
    private var lastDecodeToken = 0

    /// Puts a placeholder in the slot now and asks for the drawing off main.
    private func startDecoding(for pageID: UUID, from data: Data) -> UIView {
        lastDecodeToken += 1
        let token = lastDecodeToken
        let placeholder = makePlaceholder(saying: "This page is loading…")

        // `Task`, not `Task.detached`: this one is meant to be cancellable,
        // and detaching would detach the cancellation the checkpoints inside
        // `decodeInk` depend on.
        let task = Task { [weak self] in
            let decoded = await Self.decodeInk(data)
            guard let self else { return }
            self.installDecoded(decoded, for: pageID, token: token)
        }
        pendingDecodes[pageID] = PendingDecode(token: token, task: task)
        return placeholder
    }

    /// The expensive half, off the main actor.
    ///
    /// `nonisolated static` — the middle row of `CONTRIBUTING.md` — Getting
    /// off the main actor: heavy work over a value, owning no state, so it
    /// runs on the generic executor rather than occupying an actor's queue
    /// behind another page's decode, and it runs in its caller's task, which
    /// is what gives the checkpoints below something to observe.
    private nonisolated static func decodeInk(
        _ data: Data
    ) async -> Result<PKDrawing, any Error> {
        // Before the expense, which is where a checkpoint belongs: five
        // decodes are queued by one flick and four of them are usually
        // already unwanted by the time they are reached.
        if Task.isCancelled { return .failure(CancellationError()) }
        do {
            return .success(try PKDrawing(data: data))
        } catch {
            return .failure(error)
        }
    }

    /// Installs a decoded drawing into the slot that asked for it.
    ///
    /// The currency check is the token, and it is checked here and nowhere
    /// else. A slot that was retired has no entry; a slot rebuilt since has a
    /// newer one; either way this result is dropped rather than installed over
    /// a page that has moved on.
    private func installDecoded(
        _ decoded: Result<PKDrawing, any Error>,
        for pageID: UUID,
        token: Int
    ) {
        guard pendingDecodes[pageID]?.token == token else { return }
        pendingDecodes[pageID] = nil
        // The slot this decode was started for, which the token says is still
        // the one that asked. It is a placeholder by construction —
        // `startDecoding` put one there and only a rebuild replaces it, which
        // would have changed the token. The guard is belt and braces, and it
        // fails closed: whatever is in the slot stays, because the one thing
        // this must never do is replace a canvas, which would destroy ink.
        guard case .placeholder(let placeholder)? = slots[pageID] else { return }

        switch decoded {
        case .success(let drawing):
            placeholder.removeFromSuperview()
            slots[pageID] = .canvas(
                makeCanvas(for: pageID, installing: DrawingSnapshot(drawing: drawing))
            )
        case .failure(is CancellationError):
            // A cancel this runtime issued took the token entry with it, so
            // such a decode is already refused above and never arrives here.
            // What does arrive here is a cancellation from outside — the
            // enclosing task tree going away. It is not a decode failure and
            // must not be rendered as one: a benign cancel that told the user
            // their page "could not be read" would be the worst possible lie
            // about ink that is perfectly fine on disk.
            return
        case .failure(let error):
            // Bytes the session holds that nonetheless refuse to decode. The
            // same refusal as `.unreadable`, discovered one step later: never
            // an editable blank.
            CanvasLog.event(.canvas, "page \(pageID) drawing failed to decode: \(error)")
            placeholder.removeFromSuperview()
            slots[pageID] = .placeholder(makePlaceholder(saying: "This page could not be read."))
        }

        layoutSlots()
        if pageID == currentPageID { livePage(pageID)?.becomeActivePage() }
    }

    private func cancelDecode(for pageID: UUID) {
        pendingDecodes.removeValue(forKey: pageID)?.task.cancel()
    }

    /// Read only by tests: how many slots are waiting on a decode. That an
    /// abandoned decode was *cancelled* rather than merely refused at the
    /// install site is otherwise observable only as the absence of something,
    /// and a test that waits on an absence waits on the machine's load
    /// (`CONTRIBUTING.md` — Rules for any check you add). It computes nothing.
    var pendingInkDecodeCount: Int { pendingDecodes.count }

    private func makeCanvas(for pageID: UUID, installing snapshot: DrawingSnapshot?) -> PageCanvasController {
        // The page reports through its host from the moment it exists: there is
        // no window in which a canvas is live and reporting nowhere. What used
        // to keep the install from being reported as an edit was the *absence*
        // of that wiring until after the install; the install now hides itself
        // instead, in `PageCanvasController.installDrawing`, which is where the
        // assignment is and where a reader looking for the rule will be.
        let page = PageCanvasController(
            toolPicker: toolPicker,
            projection: session.projection(forPage: pageID),
            host: SlotHost(runtime: self, pageID: pageID),
            staticRenderer: staticRenderer
        )

        addChild(page)
        page.view.frame = slotFrame(for: position(of: pageID) ?? 0)
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
        page.setStaticLayers(session.staticLayers(forPage: pageID))

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

    /// Frames every live slot from its page's *current* position.
    ///
    /// Driven from `order` rather than from `slots`, so one pass over the
    /// document answers every slot's position — and so a slot whose page is no
    /// longer in the order is simply not framed, rather than framed somewhere
    /// arbitrary. `refreshWindow` is what removes such a slot; this never
    /// pretends it has a place.
    private func layoutSlots() {
        for (position, pageID) in order.enumerated() {
            slots[pageID]?.view.frame = slotFrame(for: position)
        }
        appendPreview.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        appendPreview.frame = appendPreviewFrame()
    }

    /// Where the appended page will open: the canonical page at its fit-page
    /// scale, centred in the slot after the last — the same numbers
    /// `PageCanvasController.establishZoomIfNeeded` and `centerPageInViewport`
    /// will produce for the real page, restated here because the preview
    /// exists before any controller does.
    private func appendPreviewFrame() -> CGRect {
        let slot = slotFrame(for: order.count)
        guard slot.width > 0, slot.height > 0 else { return .zero }
        let page = CGSize(
            width: PageGeometry.canonical.width,
            height: PageGeometry.canonical.height
        )
        let scale = min(slot.width / page.width, slot.height / page.height)
        let size = CGSize(width: page.width * scale, height: page.height * scale)
        return CGRect(
            x: slot.minX + (slot.width - size.width) / 2,
            y: slot.minY + (slot.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    #if DEBUG
    /// Read by tests: the preview's rect, to pin that the appended page's slot
    /// covers the room the preview promised and the promise is page-shaped.
    var appendPreviewFrameForTesting: CGRect { appendPreview.frame }
    var appendPreviewTakesInputForTesting: Bool { appendPreview.isUserInteractionEnabled }
    #endif

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
        guard order.indices.contains(settled) else { return }
        // The position is resolved to an identity *here*, at rest, against the
        // order as it stands — and what is reported onward is that identity.
        // A position reported to the session would name whichever page happens
        // to sit there when the session reads it, which after any list change
        // is a page the user never turned to and the session would write
        // durably as current.
        let settledPageID = order[settled]
        guard settledPageID != currentPageID else { return }

        currentPageID = settledPageID
        refreshWindow()
        livePage(settledPageID)?.becomeActivePage()
        session.currentPageChanged(to: settledPageID)
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
        guard scrollView.bounds.width > 0, !order.isEmpty else { return }
        let lastPageOffset = scrollView.bounds.width * CGFloat(order.count - 1)
        if scrollView.contentOffset.x > lastPageOffset + Self.appendTriggerFraction
            * scrollView.bounds.width {
            // The session's append drives `setPages`, which settles the new
            // page itself — synchronously, inside this call: the page count,
            // contentSize, the blank slot, and the offset all describe the new
            // page by the time the callback below returns.
            let countBeforeAppend = order.count
            session.reachedEndBoundary()
            if order.count > countBeforeAppend {
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
                // The page, not its position: by the time this runs the list
                // may name a different page at the same index, and the offset
                // this re-asserts must be the one the session just committed.
                let target = currentPageID
                // A task, not per-sample work: this runs once per append
                // gesture, at drag end (`Contract.md` — Performance).
                Task { [weak self] in
                    guard let self, self.currentPageID == target else { return }
                    let position = self.currentPageIndex
                    // A programmatic non-animated set cancels the in-flight
                    // bounce; one tick in it has barely moved, so the
                    // correction is imperceptible next to the fight it
                    // prevents. It fires no delegate callback, and none is
                    // needed: setPages already committed this index, so no
                    // second turn can exist.
                    self.scrollView.setContentOffset(
                        CGPoint(x: self.scrollView.bounds.width * CGFloat(position), y: 0),
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
    /// the last page does not trigger it — and no more than that.
    ///
    /// 0.35 was measured out of reach on hardware (2026-08-08, iPad Air 5):
    /// the rubber band damps a full natural pull to ~0.25–0.29 of the viewport
    /// width in either orientation, so every pull fell short and append was
    /// simply dead. The measured pulls put the deliberate gesture at 0.24+ of
    /// the width; 0.15 sits under the weakest of them and far above the
    /// overshoot an ordinary turn leaves at finger-lift, which arrives from
    /// the previous page and does not cross the last page's edge at all.
    private static let appendTriggerFraction: CGFloat = 0.15
}

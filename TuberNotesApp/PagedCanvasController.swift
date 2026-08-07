import PencilKit
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
final class PagedCanvasController: UIViewController, UIScrollViewDelegate {
    /// How many pages either side of the visible one stay live. One, so that a
    /// turn in either direction reveals a prepared page rather than a blank slot
    /// being built mid-gesture.
    private static let windowRadius = 1

    let scrollView = UIScrollView()

    /// The page the user is looking at. `EditorSession` owns the durable current
    /// index; this is the runtime's view of it.
    private(set) var currentPageIndex = 0
    private(set) var pageCount = 1

    /// Supplies the content for a page about to enter the window.
    ///
    /// `.loading` and `.unreadable` are the cases that matter: a page can enter
    /// the window before the session has its bytes, or with bytes that refuse
    /// to read. Such a page is a placeholder, never an editable blank — ink
    /// drawn on a blank standing in for a real page would be saved over it.
    var contentForPage: ((Int) -> PageContent)?

    enum PageContent {
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

    /// Reports that a live page's drawing changed. The index is the page's, and
    /// nothing else travels with it (`Contract.md` — Saving).
    var onDrawingChanged: ((Int) -> Void)?

    /// Hands a retiring page's ink to the session before the controller is
    /// released. Without this a page's edits would die with its canvas when it
    /// left the window.
    var onPageRetiring: ((Int, DrawingSnapshot) -> Void)?

    /// The visible page changed. Fired once per settled turn, not per frame.
    var onPageChanged: ((Int) -> Void)?

    /// The user swiped past the last page. The session decides whether a page is
    /// appended; this runtime never grows the document by itself.
    var onReachedEndBoundary: (() -> Void)?

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

    /// The shape the Pencil draws, or `nil` for freehand ink.
    ///
    /// It lives here for the same reason the tool picker does: the active tool
    /// is this runtime's state (`Contract.md` — Owners), one setting for the
    /// document rather than one per page, so choosing "rectangle" and turning
    /// the page does not silently put the pen back in your hand.
    private(set) var shapeTool: ShapeKind?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagedCanvasController is created in code only")
    }

    override func viewDidLoad() {
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollView.bounds.width > 0 else { return }

        updateContentSize()
        layoutSlots()

        if !hasSettledInitialPage {
            hasSettledInitialPage = true
            scrollTo(page: currentPageIndex, animated: false)
            refreshWindow()
            livePage(at: currentPageIndex)?.becomeActivePage()
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
    func setPages(count: Int, currentPageIndex index: Int) {
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
    func markEditable() {
        isEditable = true
        for case .canvas(let page) in slots.values {
            page.markEditable()
        }
    }

    /// Selects the shape a Pencil drag commits on every page, live or later.
    ///
    /// An intention from the SwiftUI root by way of `EditorSession`; nothing
    /// about it is durable, and no page's ink changes here.
    func setShapeTool(_ kind: ShapeKind?) {
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
    func reloadPage(at index: Int) {
        guard case .placeholder(let stale)? = slots[index] else { return }
        stale.removeFromSuperview()
        slots[index] = makeSlot(at: index)
        layoutSlots()
        if index == currentPageIndex { livePage(at: index)?.becomeActivePage() }
    }

    /// The live page controller for an index, if that slot is a canvas.
    /// Read by `snapshot(at:)` — which is how the save path reaches a live
    /// drawing — and by tests via `EditorSession.currentCanvas`.
    func livePage(at index: Int) -> PageCanvasController? {
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

    /// A snapshot of one live page, or `nil` when the page has no canvas —
    /// outside the window, or a placeholder. A placeholder accepts no input,
    /// so `nil` here never discards ink; it only ever means there is none.
    func snapshot(at index: Int) -> DrawingSnapshot? {
        livePage(at: index)?.drawingSnapshot()
    }

    // MARK: - Windowing

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
                onPageRetiring?(index, page.drawingSnapshot())
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
        switch contentForPage?(index) ?? .blank {
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
        let page = PageCanvasController(toolPicker: toolPicker)

        addChild(page)
        page.view.frame = slotFrame(for: index)
        scrollView.addSubview(page.view)
        page.didMove(toParent: self)

        // Strictly before the page becomes editable, which is the ordering
        // `PageCanvasController.installDrawing` enforces by precondition.
        if let snapshot {
            page.installDrawing(from: snapshot)
        }

        // Wired only now, after the install, and that ordering is the rule
        // rather than a tidiness preference. PencilKit reports a programmatic
        // assignment as a drawing change, synchronously, so a callback wired
        // before the install reports loading as user editing — which marked
        // every page in the opening window dirty and rewrote the document on
        // every launch (`Contract.md` — Lifecycle: "installing ink is never
        // reported as an edit").
        page.onDrawingChanged = { [weak self] in
            self?.onDrawingChanged?(index)
        }

        // A page built while the shape tool is on draws shapes too. Applied
        // after the install for the same reason the callback is: nothing about
        // the tool may participate in loading a page's ink.
        page.setShapeTool(shapeTool)

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
        onPageChanged?(settled)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag that ends past the last page's trailing edge is the append
    /// gesture. Reported, never acted on here: growing the document is the
    /// session's decision (`Contract.md` — Owners). An ordinary drag that ends
    /// without deceleration is already at rest, so it settles here.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard scrollView.bounds.width > 0 else { return }
        let lastPageOffset = scrollView.bounds.width * CGFloat(pageCount - 1)
        if scrollView.contentOffset.x > lastPageOffset + Self.appendTriggerFraction
            * scrollView.bounds.width {
            // The session's append drives `setPages`, which settles the new
            // page itself.
            onReachedEndBoundary?()
            return
        }
        if !willDecelerate { settle() }
    }

    /// How far past the last page you must pull before it counts as asking for a
    /// new one. Generous enough that the rubber-band from an ordinary turn onto
    /// the last page does not trigger it.
    private static let appendTriggerFraction: CGFloat = 0.35
}

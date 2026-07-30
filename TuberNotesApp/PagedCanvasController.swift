import PencilKit
import SwiftUI
import UIKit

/// Hosts an ordered run of pages and turns between them
/// (`Docs/Milestones/PagesAndTurning.md`).
///
/// A horizontal paging `UIScrollView` holds one page-sized slot per page, but
/// only a small window of slots has a live `PageCanvasController` in it. The
/// live count is bounded by a constant and does not grow with the page count,
/// which is what `DataContract.md` §9 requires; a retired page's controller is
/// released, not parked for a possible return.
///
/// Nesting is doing the hard work here, and it is deliberate. `PKCanvasView` is
/// itself a `UIScrollView` that owns pinch-zoom and in-page panning. A nested
/// scroll view chains to its parent once it can scroll no further in a
/// direction, so at fit-width scale — where a page cannot pan horizontally at
/// all — a horizontal drag reaches this scroll view and turns the page, and
/// zoomed in it pans within the page until it hits the page's own edge. That is
/// exactly the rule the milestone commits to in §6, obtained from the framework
/// rather than from gesture recognizers of ours.
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

    /// Supplies the saved ink for a page about to become live.
    ///
    /// `.unavailable` is the case that matters: a page can enter the window
    /// before the session has its bytes, and a canvas built then must not be
    /// editable, because ink drawn on it would be saved over the real page. Such
    /// a page is rebuilt by `reloadPage(at:)` once the bytes arrive.
    var contentForPage: ((Int) -> PageContent)?

    enum PageContent {
        case blank
        case ink(Data)
        case unavailable
    }

    /// Reports that a live page's drawing changed. The index is the page's, and
    /// nothing else travels with it (`DataContract.md` §5).
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

    /// Live page controllers by page index. Bounded by `windowRadius`.
    private var livePages: [Int: PageCanvasController] = [:]

    private var isEditable = false
    private var hasSettledInitialPage = false

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
        layoutLivePages()

        if !hasSettledInitialPage {
            hasSettledInitialPage = true
            scrollTo(page: currentPageIndex, animated: false)
            refreshWindow()
            livePages[currentPageIndex]?.becomeActivePage()
        }
    }

    // MARK: - Page set

    /// Sets the run of pages and which one is visible. Called by
    /// `EditorSession`, which owns page order and identity.
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
        livePages[index]?.becomeActivePage()
    }

    /// Opens every live page for editing, and every later one as it is built.
    func markEditable() {
        isEditable = true
        for (index, page) in livePages where !unloadedPages.contains(index) {
            page.markEditable()
        }
    }

    /// Page indices whose bytes were not ready when the page was built. They are
    /// on screen, are not editable, and are not saved.
    private(set) var unloadedPages: Set<Int> = []

    /// Rebuilds a page whose bytes have since arrived.
    ///
    /// A rebuild rather than an install, because
    /// `PageCanvasController.installDrawing` refuses to run on a canvas that is
    /// already editable — and this page never became editable, so nothing is
    /// lost by replacing it.
    func reloadPage(at index: Int) {
        guard let stale = livePages[index], unloadedPages.contains(index) else { return }
        stale.willMove(toParent: nil)
        stale.view.removeFromSuperview()
        stale.removeFromParent()
        livePages[index] = makePage(at: index)
        if index == currentPageIndex { livePages[index]?.becomeActivePage() }
    }

    /// The live page controller for an index, if it is inside the window.
    /// Present for the session's save path and for tests to assert against.
    func livePage(at index: Int) -> PageCanvasController? {
        livePages[index]
    }

    /// How many page canvases are alive. The bound §9 requires is on this
    /// number, and gate 40 asserts it does not grow with `pageCount`.
    var liveCanvasCount: Int { livePages.count }

    /// A snapshot of one live, loaded page. `nil` when the page is outside the
    /// window or was never loaded, both of which mean the session must not
    /// write it.
    func snapshot(at index: Int) -> DrawingSnapshot? {
        guard !unloadedPages.contains(index) else { return nil }
        return livePages[index]?.drawingSnapshot()
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

    /// Builds pages that entered the window and retires those that left.
    ///
    /// Retirement hands the ink to the session first and releases second. The
    /// order is the whole point: releasing first would discard edits made on a
    /// page the user simply scrolled away from.
    private func refreshWindow() {
        let wanted = windowedIndices

        for (index, page) in livePages where !wanted.contains(index) {
            // An unloaded page holds no user ink by construction, and handing its
            // blank drawing to the session would save that blank over the real
            // page.
            if !unloadedPages.contains(index) {
                onPageRetiring?(index, page.drawingSnapshot())
            }
            unloadedPages.remove(index)
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
            livePages[index] = nil
        }

        for index in wanted.sorted() where livePages[index] == nil {
            livePages[index] = makePage(at: index)
        }

        layoutLivePages()
    }

    private func makePage(at index: Int) -> PageCanvasController {
        let page = PageCanvasController(toolPicker: toolPicker)
        page.onDrawingChanged = { [weak self] in
            self?.onDrawingChanged?(index)
        }

        addChild(page)
        page.view.frame = slotFrame(for: index)
        scrollView.addSubview(page.view)
        page.didMove(toParent: self)

        // Strictly before the page becomes editable, which is the ordering
        // `PageCanvasController.installDrawing` enforces by precondition.
        var isLoaded = true
        switch contentForPage?(index) ?? .blank {
        case .blank:
            break
        case .ink(let data):
            do {
                try page.installDrawing(from: data)
            } catch {
                CanvasLog.event(
                    CanvasLog.canvas, "canvas",
                    "page \(index) drawing failed to install: \(error)"
                )
                isLoaded = false
            }
        case .unavailable:
            isLoaded = false
        }

        if isLoaded {
            unloadedPages.remove(index)
            if isEditable { page.markEditable() }
        } else {
            // Left non-editable deliberately. It shows an empty page, and ink
            // drawn on it would be saved over whatever the page really holds.
            unloadedPages.insert(index)
        }
        return page
    }

    private func layoutLivePages() {
        for (index, page) in livePages {
            page.view.frame = slotFrame(for: index)
        }
    }

    // MARK: - UIScrollViewDelegate

    /// Frame-frequency, and it stays inside this runtime: one comparison and, at
    /// a page boundary, the window update. No publication and no allocation per
    /// frame.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0, hasSettledInitialPage else { return }

        let settled = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        guard settled != currentPageIndex, (0..<pageCount).contains(settled) else { return }

        currentPageIndex = settled
        refreshWindow()
        livePages[settled]?.becomeActivePage()
        onPageChanged?(settled)
    }

    /// A drag that ends past the last page's trailing edge is the append
    /// gesture. Reported, never acted on here: growing the document is the
    /// session's decision (`DataContract.md` §2 rule 7a).
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard scrollView.bounds.width > 0 else { return }
        let lastPageOffset = scrollView.bounds.width * CGFloat(pageCount - 1)
        if scrollView.contentOffset.x > lastPageOffset + Self.appendTriggerFraction
            * scrollView.bounds.width {
            onReachedEndBoundary?()
        }
    }

    /// How far past the last page you must pull before it counts as asking for a
    /// new one. Generous enough that the rubber-band from an ordinary turn onto
    /// the last page does not trigger it.
    private static let appendTriggerFraction: CGFloat = 0.35
}

/// Hosts the paged canvas runtime in SwiftUI.
///
/// The controller is owned by `EditorSession` and merely handed here, so
/// re-evaluating the SwiftUI body cannot rebuild it or its pages
/// (`DataContract.md` §2 rule 6).
///
/// `updateUIViewController` is deliberately empty: intentions travel to the
/// session, which drives the runtime directly. Nothing about the canvas is
/// re-derived from SwiftUI state.
struct PagedCanvas: UIViewControllerRepresentable {
    let controller: PagedCanvasController

    func makeUIViewController(context: Context) -> PagedCanvasController {
        return controller
    }

    func updateUIViewController(_ controller: PagedCanvasController, context: Context) {}
}

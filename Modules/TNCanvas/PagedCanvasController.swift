import CoreGraphics
import PencilKit
import TNCore
import TNModel
import UIKit

/// The driven canvas runtime: a horizontal run of page slots, a bounded window
/// of live canvases inside it, and one reporter it answers to.
///
/// It is told and it reports. It has no notion of a notebook, no file, no
/// renderer, and no page numbers beyond the positions of the list it was last
/// given: its whole state is reconstructible from one `setPages` and N
/// installs, except the viewport, which is the tab's.
@MainActor
package final class PagedCanvasController: UIViewController, CanvasSurface, PageCanvasOwner, UIScrollViewDelegate {
    /// The reporter owns the binding that owns this runtime and outlives it, so
    /// the reference back up is unowned: a runtime that reports nowhere is a
    /// page whose ink is edited and never saved, and that state does not exist
    /// to be reached.
    private unowned let reporter: any CanvasReporting

    let scrollView = UIScrollView()

    /// The page list, in order. Identity, never position: every lookup below
    /// keys on `PageID` and positions are derived from this array.
    private var order: [PageID] = []
    private var descriptors: [PageID: PageDescriptor] = [:]

    /// What the notebook has pushed down for a page, kept whether or not the
    /// page currently has a canvas: a page outside the live window keeps its
    /// snapshot and builds a canvas when it enters.
    private var snapshots: [PageID: PageSnapshot] = [:]

    /// The live canvases, by page. Internal rather than private so a test can
    /// ask what the window built without a `…ForTesting` member existing in the
    /// build people hold.
    private(set) var canvases: [PageID: PageCanvasController] = [:]
    private var placeholders: [PageID: PagePlaceholderView] = [:]

    /// A canvas whose retire was deferred by a stroke in flight, and whose page
    /// has already left the list. It is retired, and released, when the stroke
    /// ends.
    private var retiring: [PageID: PageCanvasController] = [:]
    private var pagesToRetireWhenStrokeEnds: Set<PageID> = []

    /// Pages the notebook has given content for and has not been told the
    /// runtime let go of. It is what keeps a page from being retired twice: a
    /// canvas leaving the window reports the ink, and the page leaving the list
    /// afterwards reports nothing more.
    private var pagesAwaitingRetireReport: Set<PageID> = []

    package private(set) var currentPageID: PageID?

    /// The decoded window as last reported. `windowChanged` is sent when this
    /// changes and never per frame.
    private var reportedWindow: [PageID] = []

    private var tool: CanvasTool?
    private var canUndo = false
    private var canRedo = false

    private var lastStructureSeq: StructureSeq?
    private var nextReportSeqRaw: UInt64 = 0

    /// The end-boundary report that has not been answered yet.
    private var pendingBoundarySeq: ReportSeq?

    /// A window refresh that arrived while a stroke was in flight.
    private var windowRefreshDeferred = false

    /// The bounds the slots were laid out for.
    private var layoutBounds: CGSize = .zero

    /// A scroll asked for before the first layout existed. Consumed by the
    /// first `viewDidLayoutSubviews`, dropped by a `setPages` that no longer
    /// lists the page. Owner: this runtime, like its other scroll state.
    ///
    /// Without it the opening `scroll(to:)` — the one that puts a reopened
    /// notebook on the page it was left on — arrives while every slot is still
    /// zero-sized and is silently discarded.
    private var pendingScroll: PageID?

    package init(reporter: any CanvasReporting) {
        self.reporter = reporter
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

    /// The viewport-change hook, and the reason it is this one: every offset in
    /// this runtime is `slot width × index`, so a width change invalidates the
    /// standing `contentOffset`. Left alone, a Split View resize shows the
    /// wrong page and then reports a turn the user never made. A resize is not
    /// a page turn, so nothing here reports one; the offset is restated for the
    /// page that was already current.
    package override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = scrollView.bounds.size
        guard bounds != layoutBounds else { return }
        layoutBounds = bounds
        layoutSlots()
        anchorOnCurrentPage()
        // The first layout is also the first viewport this runtime has ever
        // had: before it, every slot is zero-sized and the window is empty, so
        // a `setPages` that arrived first built nothing. This is where it gets
        // built, and where a resize re-establishes it.
        refreshWindow()
        consumePendingScroll()
    }

    // MARK: - CanvasSurface

    package func setPages(_ pages: [PageDescriptor], seq: StructureSeq, answering: ReportSeq?) {
        if let last = lastStructureSeq {
            TNPrecondition.require(
                seq >= last,
                "setPages arrived with sequence \(seq.raw) behind \(last.raw)"
            )
        }
        lastStructureSeq = seq

        var seen = Set<PageID>()
        for page in pages {
            TNPrecondition.require(seen.insert(page.id).inserted, "setPages named page \(page.id) twice")
        }

        let previousOrder = order
        let previousIndex = currentPageID.flatMap { previousOrder.firstIndex(of: $0) }

        order = pages.map(\.id)
        descriptors = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })

        // A scroll still waiting for a viewport names a page this list may no
        // longer have. It is dropped rather than clamped: the request was for
        // that page, and nothing else answers it.
        if let pending = pendingScroll, !seen.contains(pending) {
            pendingScroll = nil
        }

        // Departures. A page that leaves the list hands its ink over before its
        // canvas is released: releasing first would discard edits made on a
        // page the user simply had open when the page was deleted elsewhere.
        for page in previousOrder where !seen.contains(page) {
            retireDepartedPage(page)
        }

        // Survivors keep their canvases, and a geometry that changed under one
        // is restated rather than rebuilt.
        for page in order {
            guard let canvas = canvases[page], let descriptor = descriptors[page] else { continue }
            canvas.updateGeometry(descriptor.geometry)
        }

        // The current page follows the *page*, not the position. If it is gone,
        // its successor at the same position takes over — the same page the
        // user is looking at after a delete.
        //
        // No turn is reported for any of this. A reconcile is not a page turn:
        // the user turned nothing, and `pageBecameCurrent` means the viewport
        // settled somewhere new. The one exception is the appended page below,
        // which the user asked for by pulling past the end.
        if let current = currentPageID, order.contains(current) {
            // Unchanged.
        } else if order.isEmpty {
            currentPageID = nil
        } else {
            currentPageID = order[min(max(previousIndex ?? 0, 0), order.count - 1)]
        }

        layoutSlots()
        anchorOnCurrentPage()
        refreshWindow()

        TNLog.event(.canvas, "setPages seq=\(seq.raw) pages=\(order.count) current=\(currentPageID.map(String.init(describing:)) ?? "none")")

        if let answering, answering == pendingBoundarySeq {
            answerEndBoundary()
        }
    }

    package func installContent(_ snapshot: PageSnapshot) {
        TNPrecondition.require(
            descriptors[snapshot.id] != nil,
            "content arrived for page \(snapshot.id), which this runtime has not been told about"
        )
        snapshots[snapshot.id] = snapshot
        pagesAwaitingRetireReport.insert(snapshot.id)

        // An install waits for a stroke in flight. Storing the value does not:
        // it is the canvas that must not be touched, and the snapshot is a
        // value nobody else can see.
        if isAnyStrokeInFlight {
            windowRefreshDeferred = true
            return
        }
        applyContent(for: snapshot.id)
        layoutSlots()
    }

    package func restoreInk(on page: PageID, _ ink: PKDrawing, seq: InkSeq) {
        TNPrecondition.require(
            descriptors[page] != nil,
            "ink was restored on page \(page), which this runtime has not been told about"
        )
        // The value is remembered whether or not the page is live: a canvas
        // built when the page enters the window carries the restored ink
        // rather than the ink the last install described, and a live canvas
        // takes it from here when a stroke in flight has deferred it.
        if let snapshot = snapshots[page], snapshot.isEditable {
            snapshots[page] = PageSnapshot.editable(
                id: page,
                ink: ink,
                layers: snapshot.layers,
                composite: snapshot.composite,
                inkSeq: seq
            )
        }
        // A restore waits for a stroke on its own page the way an install
        // waits for any: the canvas is what must not be touched, and the
        // notebook's value is already the truth. `pageStrokeDidEnd` applies
        // it. A stroke on another page holds nothing here.
        guard let canvas = canvases[page] else { return }
        if canvas.isStrokeInFlight {
            windowRefreshDeferred = true
            return
        }
        canvas.restoreInk(ink, seq: seq)
    }

    package func updateComposite(on page: PageID, _ composite: Composite, layers: [Layer]) {
        TNPrecondition.require(
            descriptors[page] != nil,
            "a composite arrived for page \(page), which this runtime has not been told about"
        )
        if let snapshot = snapshots[page], snapshot.isEditable,
           let ink = snapshot.ink, let inkSeq = snapshot.inkSeq {
            snapshots[page] = PageSnapshot.editable(
                id: page,
                ink: ink,
                layers: layers,
                composite: composite,
                inkSeq: inkSeq
            )
        }
        // The same wait as a restore, so the picture and the hit rects that
        // answer one land on the canvas with it. Only this page's stroke
        // holds it: the `.textEditingEnded` behind a commit's picture does
        // not wait, so the picture must not wait on a neighbour.
        guard let canvas = canvases[page] else { return }
        if canvas.isStrokeInFlight {
            windowRefreshDeferred = true
            return
        }
        canvas.setLayers(layers)
        canvas.updateComposite(composite)
    }

    package func beginTextEditing(on page: PageID, _ start: TextEditStart) {
        TNPrecondition.require(
            descriptors[page] != nil,
            "text editing began on page \(page), which this runtime has not been told about"
        )
        guard let canvas = canvases[page] else {
            // The page left the live window between the request and the
            // render. Answered on the canvas's behalf with the value unchanged,
            // so the notebook's session closes the one way a session closes.
            reporter.textEditingEnded(on: page, layer: start.layer, start.text)
            return
        }
        canvas.beginTextEditing(start)
    }

    package func endTextEditing(on page: PageID, layer: LayerID) {
        canvases[page]?.endTextEditing(layer: layer)
    }

    package func undoTyping() {
        for canvas in canvases.values { canvas.undoTyping() }
    }

    package func redoTyping() {
        for canvas in canvases.values { canvas.redoTyping() }
    }

    package func scroll(to page: PageID) {
        guard let index = order.firstIndex(of: page) else {
            TNPrecondition.fail("scroll(to:) named page \(page), which this runtime has not been told about")
        }
        let layout = currentLayout
        guard !layout.isEmpty else {
            // No viewport yet, so no offset exists to write. The request is
            // kept for the first layout instead of being dropped.
            pendingScroll = page
            return
        }
        let target = layout.offsetX(at: index)
        if abs(scrollView.contentOffset.x - target) < 0.5 {
            // Already there: no animation would run and no settle callback
            // would fire, so the turn is settled here instead.
            settle()
            return
        }
        scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }

    package func retire(_ page: PageID) -> RetireOutcome {
        if let canvas = canvases[page] {
            switch canvas.retire() {
            case .deferred:
                pagesToRetireWhenStrokeEnds.insert(page)
                return .deferred
            case .retired:
                releaseCanvas(page, canvas)
                showPlaceholderIfNeeded(for: page)
                layoutSlots()
                return .retired
            }
        }
        // No canvas: the page was a placeholder, and its final report says so.
        if pagesAwaitingRetireReport.remove(page) != nil {
            reporter.retired(page, finalInk: nil)
        }
        return .retired
    }

    /// Retires every live page, delivering final reports. Returns the pages
    /// whose retire was deferred because a stroke is in flight; the notebook
    /// defers its own check by exactly those.
    package func retireAll() -> [PageID] {
        var deferred: [PageID] = []
        for page in order where canvases[page] != nil || pagesAwaitingRetireReport.contains(page) {
            if retire(page) == .deferred { deferred.append(page) }
        }
        TNLog.event(.canvas, "retireAll: \(order.count) pages, \(deferred.count) deferred")
        return deferred
    }

    // MARK: - Told

    /// The editing environment: the tool, on every live canvas and on every
    /// canvas built after this.
    package func apply(_ environment: CanvasEnvironment) {
        tool = environment.tool
        for canvas in canvases.values {
            canvas.apply(tool: environment.tool)
        }
    }

    /// What the system undo gesture is allowed to offer. The depth of the
    /// stack is the notebook's, so the answer is told rather than computed.
    package func setUndoAvailability(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        for canvas in canvases.values {
            canvas.setUndoAvailability(canUndo: canUndo, canRedo: canRedo)
        }
    }

    // MARK: - Layout

    var currentLayout: SlotLayout {
        SlotLayout(slot: scrollView.bounds.size, pageCount: order.count)
    }

    private var currentIndex: Int? {
        currentPageID.flatMap { order.firstIndex(of: $0) }
    }

    private func layoutSlots() {
        let layout = currentLayout
        scrollView.contentSize = layout.contentSize
        guard !layout.isEmpty else { return }
        for (index, page) in order.enumerated() {
            let slot = layout.frame(at: index)
            canvases[page]?.view.frame = slot
            if let placeholder = placeholders[page], let descriptor = descriptors[page] {
                placeholder.frame = PageFit.rect(descriptor.geometry, in: layout.slot)
                    .offsetBy(dx: slot.minX, dy: slot.minY)
            }
        }
    }

    /// Restates the offset for the page that is already current. Not a turn,
    /// and nothing is reported.
    private func anchorOnCurrentPage() {
        let layout = currentLayout
        guard !layout.isEmpty, let index = currentIndex else { return }
        let target = CGPoint(x: layout.offsetX(at: index), y: 0)
        guard scrollView.contentOffset != target else { return }
        scrollView.setContentOffset(target, animated: false)
    }

    /// Answers the scroll that arrived before there was a viewport to answer
    /// it in. Not animated: this is the opening position, not a turn the user
    /// made, and an animation from page one would be a page turn nobody asked
    /// for. `settle()` is what reports it, so the turn is reported exactly once
    /// and by the one place that reports turns.
    private func consumePendingScroll() {
        guard let page = pendingScroll else { return }
        pendingScroll = nil
        let layout = currentLayout
        guard !layout.isEmpty, let index = order.firstIndex(of: page) else { return }
        scrollView.setContentOffset(CGPoint(x: layout.offsetX(at: index), y: 0), animated: false)
        settle()
    }

    // MARK: - The window

    private var isAnyStrokeInFlight: Bool {
        canvases.values.contains(where: \.isStrokeInFlight)
            || retiring.values.contains(where: \.isStrokeInFlight)
    }

    /// Builds the canvases the live window wants, retires the ones it does not,
    /// keeps a placeholder under every other slot in the decoded window, and
    /// tells the notebook the complete decoded window when it changes.
    ///
    /// The report is the last thing this does, because a handler answers by
    /// pushing content straight back down and must find the runtime's state
    /// already settled.
    private func refreshWindow() {
        if isAnyStrokeInFlight {
            windowRefreshDeferred = true
            return
        }
        windowRefreshDeferred = false

        let layout = currentLayout
        guard let index = currentIndex,
              let live = layout.liveWindow(around: index),
              let decoded = layout.decodedWindow(around: index)
        else {
            for (page, canvas) in canvases { retireLiveCanvas(page, canvas) }
            for (page, placeholder) in placeholders {
                placeholder.removeFromSuperview()
                placeholders[page] = nil
            }
            reportWindow([])
            return
        }

        let liveIDs = Set(live.map { order[$0] })
        let decodedIDs = decoded.map { order[$0] }

        for (page, canvas) in canvases where !liveIDs.contains(page) {
            retireLiveCanvas(page, canvas)
        }

        // Nearest the current page first: build order is the order the user
        // will reach them in.
        for position in live.sorted(by: { abs($0 - index) < abs($1 - index) }) {
            applyContent(for: order[position])
        }

        for (page, placeholder) in placeholders where !decodedIDs.contains(page) {
            placeholder.removeFromSuperview()
            placeholders[page] = nil
        }
        for page in decodedIDs where canvases[page] == nil {
            showPlaceholderIfNeeded(for: page)
        }

        layoutSlots()
        reportWindow(decodedIDs)
    }

    private func reportWindow(_ pages: [PageID]) {
        guard pages != reportedWindow else { return }
        reportedWindow = pages
        TNLog.event(.canvas, "window \(pages.count) pages")
        reporter.windowChanged(to: pages)
    }

    /// Gives a page the surface its snapshot describes: a canvas for editable
    /// content inside the live window, a placeholder for everything else.
    ///
    /// An existing canvas is never rebuilt, and its ink is touched only when
    /// the notebook has pushed ink the canvas has not taken. Its backdrop and
    /// its layers are restated, because the live ink is the runtime's working
    /// copy and an install is not an edit; a restore a stroke deferred is.
    private func applyContent(for page: PageID) {
        guard let snapshot = snapshots[page], let descriptor = descriptors[page] else { return }

        guard snapshot.isEditable else {
            // Placeholder, never blank, and never an editable canvas over bytes
            // the notebook refused.
            if let canvas = canvases[page] { retireLiveCanvas(page, canvas) }
            showPlaceholderIfNeeded(for: page)
            return
        }

        guard isLive(page) else {
            showPlaceholderIfNeeded(for: page)
            return
        }

        if let canvas = canvases[page] {
            canvas.setLayers(snapshot.layers)
            if let composite = snapshot.composite {
                canvas.updateComposite(composite)
            }
            // The sequence names the ink value the notebook last pushed, and
            // the canvas holds the one it last took; they differ only when a
            // stroke deferred a restore.
            if let ink = snapshot.ink, let seq = snapshot.inkSeq, seq != canvas.inkSeq {
                canvas.restoreInk(ink, seq: seq)
            }
            canvas.setUndoAvailability(canUndo: canUndo, canRedo: canRedo)
            return
        }

        let canvas = PageCanvasController(
            pageID: page,
            geometry: descriptor.geometry,
            ink: snapshot.ink ?? PKDrawing(),
            inkSeq: snapshot.inkSeq,
            composite: snapshot.composite,
            layers: snapshot.layers,
            tool: tool,
            canUndo: canUndo,
            canRedo: canRedo,
            owner: self,
            reporter: reporter
        )
        addChild(canvas)
        scrollView.addSubview(canvas.view)
        canvas.didMove(toParent: self)
        canvases[page] = canvas
        if let placeholder = placeholders.removeValue(forKey: page) {
            placeholder.removeFromSuperview()
        }
        TNLog.event(.canvas, "canvas built for page \(page)")
    }

    private func isLive(_ page: PageID) -> Bool {
        guard let index = currentIndex,
              let live = currentLayout.liveWindow(around: index),
              let position = order.firstIndex(of: page)
        else { return false }
        return live.contains(position)
    }

    private func showPlaceholderIfNeeded(for page: PageID) {
        guard canvases[page] == nil, descriptors[page] != nil else { return }
        let text: String
        if let snapshot = snapshots[page], let fault = snapshot.faults.first {
            text = PlaceholderCopy.text(for: fault)
        } else {
            text = PlaceholderCopy.waiting
        }
        if let existing = placeholders[page] {
            existing.text = text
            return
        }
        let placeholder = PagePlaceholderView(frame: .zero)
        placeholder.text = text
        scrollView.addSubview(placeholder)
        placeholders[page] = placeholder
    }

    // MARK: - Retiring

    /// A canvas leaving the live window. The page stays; its working copy does
    /// not, so the ink goes home first.
    private func retireLiveCanvas(_ page: PageID, _ canvas: PageCanvasController) {
        switch canvas.retire() {
        case .deferred:
            pagesToRetireWhenStrokeEnds.insert(page)
        case .retired:
            releaseCanvas(page, canvas)
            showPlaceholderIfNeeded(for: page)
        }
    }

    /// A page leaving the list. Its canvas, its snapshot, and its placeholder
    /// all go, and exactly one final report is delivered for it.
    private func retireDepartedPage(_ page: PageID) {
        if let canvas = canvases[page] {
            // Held aside before the retire, so every report the retire makes
            // on the way out, a text session committing in particular, is a
            // dead letter: the notebook has already let the page go.
            canvases[page] = nil
            retiring[page] = canvas
            switch canvas.retire() {
            case .deferred:
                // Never interrupt a stroke, even for a page that is gone: the
                // canvas stays aside, out of the layout, until the stroke
                // commits and its ink can be reported.
                pagesToRetireWhenStrokeEnds.insert(page)
            case .retired:
                releaseCanvas(page, canvas)
            }
        } else if pagesAwaitingRetireReport.remove(page) != nil {
            reporter.retired(page, finalInk: nil)
        }
        snapshots[page] = nil
        pagesAwaitingRetireReport.remove(page)
        if let placeholder = placeholders.removeValue(forKey: page) {
            placeholder.removeFromSuperview()
        }
    }

    private func releaseCanvas(_ page: PageID, _ canvas: PageCanvasController) {
        canvas.willMove(toParent: nil)
        canvas.view.removeFromSuperview()
        canvas.removeFromParent()
        canvases[page] = nil
        retiring[page] = nil
    }

    // MARK: - PageCanvasOwner

    func pageDidChangeInk(_ page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        // A canvas in `retiring` belongs to a page the list no longer names, so
        // the notebook has already let the page go and would trap on a report
        // for it. The stroke's ink is not lost: the retire that follows the
        // stroke's end carries the whole drawing in its final report.
        guard retiring[page] == nil else { return }
        // A restore this stroke deferred is about to replace the drawing the
        // stroke committed into. The notebook already holds the restored
        // value; this report would be taken for an edit of it, and the echo
        // that follows for another.
        if let canvas = canvases[page], let seq = snapshots[page]?.inkSeq, seq != canvas.inkSeq { return }
        reporter.inkChanged(on: page, ink, echoOf: echoOf)
    }

    // The same rule for the text reports: a canvas in `retiring` is a dead
    // letter. A draft it commits on the way out is not carried anywhere; the
    // page is gone, and so is the box.
    func pageDidRequestTextBox(_ page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        guard retiring[page] == nil else { return }
        reporter.textBoxRequested(on: page, at: point, style: style, alignment: alignment)
    }

    func pageDidRequestTextEdit(_ page: PageID, layer: LayerID) {
        guard retiring[page] == nil else { return }
        reporter.textEditRequested(on: page, layer: layer)
    }

    func pageDidEndTextEditing(_ page: PageID, layer: LayerID, _ text: TextLayer) {
        guard retiring[page] == nil else { return }
        reporter.textEditingEnded(on: page, layer: layer, text)
    }

    func pagingPanGestureRecognizer() -> UIGestureRecognizer? {
        scrollView.panGestureRecognizer
    }

    /// The canvas's one final report, on its way to the notebook.
    ///
    /// The stored snapshot takes the same value, so a page that leaves the live
    /// window and comes back is rebuilt from the ink it left with rather than
    /// from the ink the last install described. The notebook will usually push
    /// content again first; this is what makes the case where it does not a
    /// stale composite rather than lost strokes.
    func pageDidRetire(_ page: PageID, finalInk: PKDrawing) {
        if let snapshot = snapshots[page], snapshot.isEditable, let inkSeq = snapshot.inkSeq {
            snapshots[page] = PageSnapshot.editable(
                id: page,
                ink: finalInk,
                layers: snapshot.layers,
                composite: snapshot.composite,
                inkSeq: inkSeq
            )
        }
        pagesAwaitingRetireReport.remove(page)
        TNLog.event(.canvas, "retired page \(page)")
        reporter.retired(page, finalInk: finalInk)
    }

    /// The stroke committed. Everything that waited for it runs now, retires
    /// first: a page that is already gone must not be given a canvas again by
    /// the window refresh that follows.
    func pageStrokeDidEnd(_ page: PageID) {
        if pagesToRetireWhenStrokeEnds.remove(page) != nil {
            if let canvas = retiring[page] ?? canvases[page] {
                if canvas.retire() == .retired {
                    releaseCanvas(page, canvas)
                }
            }
        }
        if windowRefreshDeferred {
            for page in order { applyContent(for: page) }
            refreshWindow()
        }
    }

    func pageDidActivateLink(_ page: PageID, layer: LayerID) {
        reporter.linkActivated(on: page, layer: layer)
    }

    // MARK: - UIScrollViewDelegate

    package func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    package func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag that ends past the last slot is the append gesture. Reported,
    /// never acted on here: growing the notebook is the notebook's decision. An
    /// ordinary drag that ends without deceleration is already at rest, so it
    /// settles here.
    package func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        let layout = currentLayout
        if layout.isPastEnd(offsetX: scrollView.contentOffset.x) {
            reportEndBoundary()
            return
        }
        if !willDecelerate { settle() }
    }

    /// The current page at rest, and the one place a turn is reported.
    ///
    /// Called from the three settle callbacks and from the programmatic offset
    /// writes that fire none of them. Never per frame.
    private func settle() {
        let layout = currentLayout
        guard let index = layout.settledIndex(atOffsetX: scrollView.contentOffset.x) else { return }
        let settled = order[index]
        guard settled != currentPageID else { return }

        currentPageID = settled
        refreshWindow()
        TNLog.event(.canvas, "current page \(settled)")
        reporter.pageBecameCurrent(settled)
    }

    // MARK: - The end boundary

    private func nextReportSeq() -> ReportSeq {
        nextReportSeqRaw += 1
        return ReportSeq(nextReportSeqRaw)
    }

    private func reportEndBoundary() {
        let seq = nextReportSeq()
        pendingBoundarySeq = seq
        TNLog.event(.canvas, "end boundary reached seq=\(seq.raw)")
        reporter.endBoundaryReached(seq: seq)
        // Answered synchronously inside the report, or not at all: a `setPages`
        // that arrives later in this same turn still finds the latch. If none
        // comes, the rubber-band settles back on its own and the latch is
        // dropped so a much later push cannot yank the user forward.
        guard pendingBoundarySeq == seq else { return }
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, self.pendingBoundarySeq == seq else { return }
            self.pendingBoundarySeq = nil
        }
    }

    /// The notebook appended. The runtime shows the new last page.
    private func answerEndBoundary() {
        pendingBoundarySeq = nil
        guard let last = order.last, let index = order.firstIndex(of: last) else { return }
        let layout = currentLayout
        guard !layout.isEmpty else { return }
        currentPageID = last
        scrollView.setContentOffset(CGPoint(x: layout.offsetX(at: index), y: 0), animated: false)
        refreshWindow()

        // UIKit computed this gesture's deceleration target *before* the
        // delegate call that reported the boundary, against a contentSize that
        // still ended at the old last page, and it arms that animation after
        // the callback returns — overriding the offset just written and
        // rubber-banding back, with the overscroll's grey filling the screen
        // while the two fight. An offset write inside the callback cannot
        // cancel an animation that has not started yet, so the target is
        // re-asserted on the next runloop turn, where a programmatic,
        // non-animated set reliably kills the in-flight bounce. Once per append
        // gesture, not per frame.
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, self.currentPageID == last,
                  let position = self.order.firstIndex(of: last) else { return }
            let layout = self.currentLayout
            guard !layout.isEmpty else { return }
            self.scrollView.setContentOffset(
                CGPoint(x: layout.offsetX(at: position), y: 0), animated: false
            )
        }

        // A non-animated programmatic set fires no settle callback, and this
        // one is a genuine turn: the user asked for the page by pulling past
        // the end and is now looking at it.
        TNLog.event(.canvas, "appended page is current \(last)")
        reporter.pageBecameCurrent(last)
    }
}

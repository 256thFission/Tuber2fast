import PencilKit
import Testing
import UIKit

@testable import TuberNotes

@Suite("Paged canvas runtime")
@MainActor
struct PagedCanvasControllerTests {
    @Test("A page-sized slot exists for every page")
    func contentSizeCoversEveryPage() {
        let controller = hosted()
        controller.setPages(count: 7, currentPageIndex: 0)

        let scroll = controller.scrollView
        #expect(scroll.contentSize.width == scroll.bounds.width * 7)
        #expect(scroll.contentSize.height == scroll.bounds.height)
        #expect(scroll.isPagingEnabled)
    }

    @Test("Only a bounded window of pages is live, however many pages exist")
    func liveCanvasCountIsBounded() {
        let controller = hosted()

        for count in [1, 2, 5, 40, 400] {
            controller.setPages(count: count, currentPageIndex: 0)
            // The window is the visible page and two either side. It is the
            // count that matters, not the number: it must not scale with
            // `count` (`Contract.md` — Performance), which is why the assertion
            // survived the window growing from one either side to two.
            #expect(controller.liveCanvasCount <= 5)
            #expect(controller.liveCanvasCount <= count)
        }
    }

    @Test("Sweeping across many pages does not accumulate canvases")
    func longSweepDoesNotAccumulateCanvases() {
        let controller = hosted()
        controller.setPages(count: 120, currentPageIndex: 0)

        var highWaterMark = controller.liveCanvasCount
        for page in 0..<120 {
            turn(controller, to: page)
            highWaterMark = max(highWaterMark, controller.liveCanvasCount)
        }

        // The failure this catches is retention that grows with pages visited —
        // the multi-page form of the monotonic retention `Contract.md` —
        // Performance forbids.
        #expect(highWaterMark <= 5)
        #expect(controller.liveCanvasCount <= 5)
    }

    @Test("Two pages either side are prepared, not placeholders")
    func theWindowReachesTwoPagesEitherSide() {
        let controller = hosted()
        controller.setPages(count: 9, currentPageIndex: 0)
        turn(controller, to: 4)

        // The device finding this answers (2026-08-07): a *flick* crosses two
        // slots before anything settles, and with one prepared neighbour the
        // second slot was still a placeholder when it came under the finger.
        for index in 2...6 {
            #expect(controller.livePage(at: index) != nil, "page \(index) is inside the window")
        }
        // Still bounded, and still symmetric — the window is a radius, not a
        // lead in the direction of travel.
        #expect(controller.livePage(at: 1) == nil)
        #expect(controller.livePage(at: 7) == nil)
    }

    @Test("A page that leaves the window hands its ink over before it is released")
    func retiringPageSurrendersItsInk() {
        var retired: [Int] = []
        let controller = hosted { $0.onPageRetiring = { index, _ in retired.append(index) } }
        controller.setPages(count: 10, currentPageIndex: 0)
        controller.markEditable()

        turn(controller, to: 5)

        // Page 0 cannot still be live, and must not have been dropped silently.
        #expect(controller.livePage(at: 0) == nil)
        #expect(retired.contains(0))
    }

    @Test("A page whose ink has not arrived is a placeholder, not a canvas")
    func pageWithoutBytesIsNotACanvas() {
        let controller = hosted { $0.contentForPage = { _ in .loading } }
        controller.setPages(count: 3, currentPageIndex: 0)
        controller.markEditable()

        // The hazard this refuses: an empty canvas the user could draw on,
        // whose blank drawing would then be saved over the page's real ink —
        // or whose accepted strokes would be silently dropped. There is no
        // canvas, so neither can exist.
        #expect(controller.livePage(at: 0) == nil)
        #expect(controller.liveCanvasCount == 0)
        #expect(controller.snapshot(at: 0) == nil)
    }

    @Test("An unreadable page is refused, never rendered as an editable blank")
    func unreadablePageIsRefused() {
        let controller = hosted { $0.contentForPage = { _ in .unreadable("decode failed") } }
        controller.setPages(count: 2, currentPageIndex: 0)
        controller.markEditable()

        #expect(controller.livePage(at: 0) == nil)
        #expect(controller.snapshot(at: 0) == nil)
    }

    @Test("A page is rebuilt with its ink once the bytes arrive")
    func reloadInstallsLateArrivingInk() throws {
        var available: Data?
        let controller = hosted {
            $0.contentForPage = { _ in
                guard let available else { return .loading }
                return .ink(available)
            }
        }
        controller.setPages(count: 2, currentPageIndex: 0)
        controller.markEditable()
        #expect(controller.livePage(at: 0) == nil)

        available = strokeAcrossPage().dataRepresentation()
        controller.reloadPage(at: 0)

        let page = try #require(controller.livePage(at: 0))
        #expect(page.canvasView.drawing.strokes.count == 1)
    }

    @Test("Reloading a slot that is a live canvas does nothing")
    func reloadNeverReplacesACanvas() throws {
        let controller = hosted { $0.contentForPage = { _ in .blank } }
        controller.setPages(count: 2, currentPageIndex: 0)
        controller.markEditable()

        let page = try #require(controller.livePage(at: 0))
        page.canvasView.drawing = strokeAcrossPage()

        // A canvas holds ink; only retirement may replace it. A reload here
        // would destroy the stroke with an older load result.
        controller.reloadPage(at: 0)

        let after = try #require(controller.livePage(at: 0))
        #expect(after === page)
        #expect(after.canvasView.drawing.strokes.count == 1)
    }

    @Test("A turn commits once, at rest, from any settle callback")
    func pageChangeIsReportedOnceWhenSettled() {
        var reported: [Int] = []
        let controller = hosted { $0.onPageChanged = { reported.append($0) } }
        controller.setPages(count: 5, currentPageIndex: 0)
        let scroll = controller.scrollView

        // A deceleration that comes to rest on page 1.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width, y: 0)
        controller.scrollViewDidEndDecelerating(scroll)
        // A drag that ends dead on page 2 with no deceleration.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
        // Settling again in the same place is not another turn.
        controller.scrollViewDidEndDecelerating(scroll)
        controller.scrollViewDidEndScrollingAnimation(scroll)

        #expect(reported == [1, 2])
    }

    @Test("A half-drag past the midpoint commits nothing")
    func halfDragCommitsNothing() throws {
        var reported: [Int] = []
        let controller = hosted { $0.onPageChanged = { reported.append($0) } }
        controller.setPages(count: 5, currentPageIndex: 0)
        let before = try #require(controller.livePage(at: 0))
        let scroll = controller.scrollView

        // The finger is past the halfway point of a drag toward page 1. The
        // old runtime declared the turn settled here — rebuilding the window,
        // stealing first responder, and arming a save for a turn the user may
        // yet abandon. Nothing has settled: no callback fires mid-drag.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 0.7, y: 0)
        #expect(reported.isEmpty)
        #expect(controller.currentPageIndex == 0)

        // The drag is abandoned; the scroll snaps back and rests where it
        // began. The abandoned half-drag has retired and rebuilt nothing.
        scroll.contentOffset = .zero
        controller.scrollViewDidEndDecelerating(scroll)
        #expect(reported.isEmpty)
        #expect(controller.currentPageIndex == 0)
        #expect(controller.livePage(at: 0) === before)
    }

    @Test("A fast fling across several pages fires one turn, for the landing page")
    func flingAcrossPagesReportsOneTurn() {
        var reported: [Int] = []
        let controller = hosted { $0.onPageChanged = { reported.append($0) } }
        controller.setPages(count: 6, currentPageIndex: 0)
        let scroll = controller.scrollView

        // The finger crosses the midpoints of pages 1 and 2 mid-gesture. No
        // frame in that sweep is a turn: the consumers this signal feeds —
        // prefetch, eviction, current-page bookkeeping, and soon background
        // decodes — must pay once per landing, not once per midpoint crossed.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 1.6, y: 0)
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.4, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: true)
        #expect(reported.isEmpty)

        // Deceleration carries it to rest on page 3. That rest is the turn,
        // exactly one, named for the landing page.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 3, y: 0)
        controller.scrollViewDidEndDecelerating(scroll)

        #expect(reported == [3])
        #expect(controller.currentPageIndex == 3)
    }

    @Test("Pulling past the last page asks for a new one, and never adds it")
    func endBoundaryIsReportedNotActedOn() {
        var asked = 0
        let controller = hosted { $0.onReachedEndBoundary = { asked += 1 } }
        controller.setPages(count: 3, currentPageIndex: 2)

        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.5, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)

        #expect(asked == 1)
        // The runtime never grows the document by itself (`Contract.md` — Owners).
        #expect(controller.pageCount == 3)
    }

    @Test("Settling on the last page does not ask for a new one")
    func ordinaryTurnOntoLastPageDoesNotAppend() {
        var asked = 0
        let controller = hosted { $0.onReachedEndBoundary = { asked += 1 } }
        controller.setPages(count: 3, currentPageIndex: 2)

        let scroll = controller.scrollView
        // A small rubber-band overshoot from an ordinary turn, well short of the
        // deliberate pull the append gesture requires.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.1, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)

        #expect(asked == 0)
    }

    /// The appended blank page must be there the moment the drag ends: a blank
    /// page has nothing to load, so no loading placeholder may ever stand in
    /// for it, and the slots already on screen must not be rebuilt around it
    /// (device finding, 2026-08-07: the whole area flashed grey on append).
    @Test("An appended blank page is a ready canvas immediately, and existing slots survive")
    func appendedBlankPageIsReadyImmediately() throws {
        var count = 3
        let controller = hosted { $0.contentForPage = { _ in .blank } }
        controller.setPages(count: count, currentPageIndex: 2)
        controller.markEditable()
        // The session's shape: the append is synchronous in intent.
        controller.onReachedEndBoundary = { [unowned controller] in
            count += 1
            controller.setPages(count: count, currentPageIndex: count - 1)
        }
        let kept = try #require(controller.livePage(at: 2))

        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.5, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: true)

        // Immediately — before any runloop turn, fetch, or animation — the new
        // slot is a live, editable, empty canvas, never a placeholder.
        let appended = try #require(controller.livePage(at: 3))
        #expect(appended.canvasView.drawing.strokes.isEmpty)
        #expect(controller.currentPageIndex == 3)
        // And the slot the user was just writing on was not rebuilt.
        #expect(controller.livePage(at: 2) === kept)
    }

    /// The device finding of 2026-08-07: the turn onto the appended page
    /// sometimes rubber-banded back. UIKit computes the gesture's deceleration
    /// target before `scrollViewDidEndDragging`, against the contentSize that
    /// still ends at the old last page, and arms that animation after the
    /// delegate returns — overriding the offset `setPages` wrote. The runtime
    /// re-asserts the target on the next runloop turn, which cancels the
    /// bounce. This test plants that override and fails without the re-assert.
    @Test("The append gesture lands on the new page even against the armed rubber-band")
    func appendGestureLandsOnTheNewPage() async throws {
        var count = 3
        let controller = hosted { $0.contentForPage = { _ in .blank } }
        controller.setPages(count: count, currentPageIndex: 2)
        controller.onReachedEndBoundary = { [unowned controller] in
            count += 1
            controller.setPages(count: count, currentPageIndex: count - 1)
        }

        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.5, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: true)

        // The bookkeeping is synchronous: the content spans the new page, so
        // the gesture has somewhere to land, and the offset already names it.
        #expect(controller.pageCount == 4)
        #expect(scroll.contentSize.width == scroll.bounds.width * 4)
        #expect(scroll.contentOffset.x == scroll.bounds.width * 3)

        // UIKit's armed bounce drags the offset back toward the old last page.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.3, y: 0)

        // The re-assert queued at drag end must win, and no turn away from the
        // committed index may fire.
        for _ in 0..<20 {
            await Task.yield()
            if scroll.contentOffset.x == scroll.bounds.width * 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scroll.contentOffset.x == scroll.bounds.width * 3)
        #expect(controller.currentPageIndex == 3)
    }

    /// A pull that ends short of the trigger is an abandoned drag: no append,
    /// no queued re-assert fighting the ordinary rubber-band, and the settle
    /// back onto the last real page is not a turn.
    @Test("An abandoned pull below the trigger appends nothing and rubber-bands cleanly")
    func abandonedPullBelowTriggerRubberBandsCleanly() async throws {
        var asked = 0
        var reported: [Int] = []
        let controller = hosted {
            $0.onReachedEndBoundary = { asked += 1 }
            $0.onPageChanged = { reported.append($0) }
        }
        controller.setPages(count: 3, currentPageIndex: 2)

        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2.3, y: 0)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: true)
        #expect(asked == 0)
        #expect(controller.pageCount == 3)
        #expect(scroll.contentSize.width == scroll.bounds.width * 3)

        // The rubber-band returns to the last real page and settles there.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2, y: 0)
        controller.scrollViewDidEndDecelerating(scroll)
        #expect(reported.isEmpty)
        #expect(controller.currentPageIndex == 2)

        // And nothing queued at drag end moves the offset afterwards. A
        // non-event has nothing to wait *for*, so the window is wall time —
        // the one shape of timing wait this suite still keeps.
        try await Task.sleep(for: .milliseconds(20))
        #expect(scroll.contentOffset.x == scroll.bounds.width * 2)
    }

    // MARK: - Mixed geometry

    /// The ordinary state of an annotated import: a portrait page, a landscape
    /// worksheet, and the blank canonical page a swipe past the end appends.
    /// Each page's canvas is built with its own geometry, and every page in the
    /// run is reachable — the arithmetic that lands a turn is the same for all
    /// three because the *slot* is uniform even though the pages are not.
    @Test("Paging lands correctly across a mixed-geometry run")
    func mixedGeometryRunTurnsCorrectly() throws {
        let geometries: [PageGeometry] = [
            .canonical,
            PageGeometry(width: 842, height: 595),
            .canonical,
        ]
        let controller = hosted {
            $0.projectionForPage = { index in
                PageProjection(
                    geometry: geometries[index],
                    zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
                )
            }
        }
        controller.setPages(count: geometries.count, currentPageIndex: 0)
        controller.markEditable()
        controller.view.layoutIfNeeded()

        let scroll = controller.scrollView
        // A slot is one viewport wide whatever the page in it measures, so the
        // content is exactly the run of pages and nothing is left over.
        #expect(scroll.contentSize.width == scroll.bounds.width * 3)

        for page in [0, 1, 2, 1, 0, 2] {
            turn(controller, to: page)
            // A slot that entered the window this turn was built during the
            // settle and has not laid out yet; the app gets this pass from the
            // run loop.
            controller.view.layoutIfNeeded()
            #expect(controller.currentPageIndex == page)

            let canvas = try #require(controller.livePage(at: page)).canvasView
            let expected = geometries[page]
            let unscaled = CGSize(
                width: canvas.contentSize.width / canvas.zoomScale,
                height: canvas.contentSize.height / canvas.zoomScale
            )
            #expect(abs(Double(unscaled.width) - expected.width) < 0.5)
            #expect(abs(Double(unscaled.height) - expected.height) < 0.5)

            // The page sits inside its slot: it opens at its own fit-width, and
            // the room left over falls evenly on both sides rather than pinning
            // to a corner.
            #expect(abs(Double(canvas.zoomScale) - Double(scroll.bounds.width) / expected.width) < 0.001)
            #expect(canvas.contentInset.left == canvas.contentInset.right)
            #expect(canvas.contentInset.top == canvas.contentInset.bottom)

            // And its slot is where the arithmetic says it is: neighbours never
            // bleed in, so nothing about the page's own size moves the turn.
            #expect(canvas.superview?.frame == CGRect(
                x: scroll.bounds.width * CGFloat(page),
                y: 0,
                width: scroll.bounds.width,
                height: scroll.bounds.height
            ))
        }
    }

    /// A landscape page next to a portrait one gets its own zoom floor — its
    /// own fit-width, since the floor is fit-width (maintainer verdict, device
    /// session 2026-08-07). Sharing a floor would mean one of the two pages
    /// resting with dead space beside it.
    @Test("Each page's zoom floor comes from its own geometry")
    func floorsAreNotSharedAcrossMixedGeometry() throws {
        let landscape = PageGeometry(width: 842, height: 595)
        let controller = hosted {
            $0.projectionForPage = { index in
                PageProjection(
                    geometry: index == 1 ? landscape : .canonical,
                    zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
                )
            }
        }
        controller.setPages(count: 2, currentPageIndex: 0)
        controller.view.layoutIfNeeded()

        let portraitCanvas = try #require(controller.livePage(at: 0)).canvasView
        let landscapeCanvas = try #require(controller.livePage(at: 1)).canvasView
        let slot = controller.scrollView.bounds

        #expect(portraitCanvas.minimumZoomScale != landscapeCanvas.minimumZoomScale)
        #expect(abs(landscape.width * Double(landscapeCanvas.minimumZoomScale)
            - Double(slot.width)) < 0.001)
        #expect(abs(PageGeometry.canonical.width * Double(portraitCanvas.minimumZoomScale)
            - Double(slot.width)) < 0.001)

        // One document, one ceiling.
        #expect(portraitCanvas.maximumZoomScale == landscapeCanvas.maximumZoomScale)
    }

    /// The live route is a Split View or Slide Over resize: the window's width
    /// changes under a document sitting mid-run. Every offset in the runtime is
    /// `bounds.width × index`, so the standing `contentOffset` addresses a
    /// different page the instant the width changes.
    @Test("A viewport width change keeps the same page centred")
    func widthChangeRecentresTheCurrentPage() throws {
        var turns: [Int] = []
        let controller = hosted { $0.onPageChanged = { turns.append($0) } }
        controller.setPages(count: 9, currentPageIndex: 0)
        turn(controller, to: 4)
        #expect(turns == [4])

        // Typed, not written as literals inside the expectations: bare literal
        // arithmetic there infers `Int` and compares unequal to any `CGFloat`.
        let narrow: CGFloat = 500
        resize(controller, toWidth: narrow)

        let scroll = controller.scrollView
        #expect(scroll.bounds.width == narrow)
        #expect(scroll.contentSize.width == narrow * 9)
        // The page, not the offset, is what survives a resize.
        #expect(scroll.contentOffset.x == narrow * 4)
        #expect(controller.currentPageIndex == 4)
        // A resize is not a page turn, and must not be reported as one.
        #expect(turns == [4])
        #expect(try #require(controller.livePage(at: 4)).view.frame
            == CGRect(x: narrow * 4, y: 0, width: narrow, height: 1180))
    }

    /// The durable half of the same defect: a stale offset divided by the new
    /// width rounds to a page the user never turned to, and the settle reports
    /// it to `EditorSession`, which writes `currentPageIndex` to disk.
    @Test("A settle after a width change reports no turn the user did not make")
    func widthChangeCausesNoDurableIndexDrift() {
        for newWidth in [500.0, 1180.0] as [CGFloat] {
            var turns: [Int] = []
            let controller = hosted { $0.onPageChanged = { turns.append($0) } }
            controller.setPages(count: 9, currentPageIndex: 0)
            turn(controller, to: 8)
            turns.removeAll()

            resize(controller, toWidth: newWidth)
            // The next thing the user does is scroll; this is that scroll coming
            // to rest without having crossed a page boundary.
            controller.scrollViewDidEndDecelerating(controller.scrollView)

            #expect(turns.isEmpty, "no turn is reported for a resize at width \(newWidth)")
            #expect(controller.currentPageIndex == 8)
        }
    }

    /// A laid-out runtime.
    ///
    /// `configure` runs before the first layout on purpose: the initial window
    /// is built during layout, so a callback installed afterwards would never be
    /// asked about the pages that already exist. The app has the same ordering —
    /// `EditorSession` wires its callbacks when it creates the controller, long
    /// before SwiftUI hosts it.
    private func hosted(
        configure: (PagedCanvasController) -> Void = { _ in }
    ) -> PagedCanvasController {
        let controller = PagedCanvasController()
        configure(controller)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        return controller
    }

    /// Changes the hosted width the way a Split View resize does: the window's
    /// frame changes and layout runs. No transition coordinator is involved,
    /// which is the point — a resize is not a rotation.
    private func resize(_ controller: PagedCanvasController, toWidth width: CGFloat) {
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: width, height: root.frame.height)
        root.setNeedsLayout()
        root.layoutIfNeeded()
    }

    /// Drives a page turn the way a settled scroll does, without a gesture:
    /// the offset comes to rest on the page and the settle callback fires.
    private func turn(_ controller: PagedCanvasController, to page: Int) {
        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        controller.scrollViewDidEndDecelerating(scroll)
    }

    private func strokeAcrossPage() -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 40, y: 60),
                timeOffset: 0,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 500, y: 700),
                timeOffset: 0.1,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        let stroke = PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        )
        return PKDrawing(strokes: [stroke])
    }
}

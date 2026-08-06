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
            // The window is the visible page and one either side. It is the
            // count that matters, not the number: it must not scale with
            // `count` (`Contract.md` — Performance).
            #expect(controller.liveCanvasCount <= 3)
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
        #expect(highWaterMark <= 3)
        #expect(controller.liveCanvasCount <= 3)
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

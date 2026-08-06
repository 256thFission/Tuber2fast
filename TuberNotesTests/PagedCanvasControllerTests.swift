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

    @Test("A page built before its ink arrives is not editable")
    func unloadedPageIsNotEditable() {
        let controller = hosted { $0.contentForPage = { _ in .unavailable } }
        controller.setPages(count: 3, currentPageIndex: 0)
        controller.markEditable()

        // The hazard: an empty canvas the user can draw on, whose blank drawing
        // would then be saved over the page's real ink.
        #expect(controller.unloadedPages.contains(0))
        // It is on screen — it is simply not editable and not saveable.
        #expect(controller.livePage(at: 0) != nil)
        #expect(controller.snapshot(at: 0) == nil)
    }

    @Test("A page is rebuilt with its ink once the bytes arrive")
    func reloadInstallsLateArrivingInk() throws {
        var available: Data?
        let controller = hosted {
            $0.contentForPage = { _ in
                guard let available else { return .unavailable }
                return .ink(available)
            }
        }
        controller.setPages(count: 2, currentPageIndex: 0)
        controller.markEditable()
        #expect(controller.unloadedPages.contains(0))

        available = strokeAcrossPage().dataRepresentation()
        controller.reloadPage(at: 0)

        #expect(!controller.unloadedPages.contains(0))
        let page = try #require(controller.livePage(at: 0))
        #expect(page.canvasView.drawing.strokes.count == 1)
    }

    @Test("A settled scroll reports the new page exactly once")
    func pageChangeIsReportedOnceWhenSettled() {
        var reported: [Int] = []
        let controller = hosted { $0.onPageChanged = { reported.append($0) } }
        controller.setPages(count: 5, currentPageIndex: 0)

        turn(controller, to: 1)
        turn(controller, to: 2)
        // A second scroll to the same place is not another turn.
        controller.scrollView.contentOffset = CGPoint(
            x: controller.scrollView.bounds.width * 2,
            y: 0
        )
        controller.scrollViewDidScroll(controller.scrollView)

        #expect(reported == [1, 2])
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

    /// Drives a page turn the way a settled scroll does, without a gesture.
    private func turn(_ controller: PagedCanvasController, to page: Int) {
        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        controller.scrollViewDidScroll(scroll)
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

import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// Configuration invariants of a canvas runtime.
@Suite("Canvas runtime", .serialized)
@MainActor
struct PageCanvasControllerTests {
    @Test("The canvas owner configures page space, input policy, and fit zoom")
    func canvasInvariants() {
        let controller = PageCanvasController()
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView

        // Exactly one live canvas view in the hierarchy.
        #expect(pkCanvasViews(in: root).count == 1)

        // Finger navigates, Pencil writes.
        #expect(canvas.drawingPolicy == .pencilOnly)

        // The canvas content coordinate system is page space. UIScrollView
        // reports contentSize already multiplied by zoomScale, so divide it out
        // to recover the unscaled page.
        let unscaled = CGSize(
            width: canvas.contentSize.width / canvas.zoomScale,
            height: canvas.contentSize.height / canvas.zoomScale
        )
        #expect(abs(unscaled.width - PageGeometry.width) < 0.5)
        #expect(abs(unscaled.height - PageGeometry.initialHeight) < 0.5)

        // The opening scale fits the page width — the scale to write at.
        let fitWidth = root.frame.width / PageGeometry.width
        #expect(abs(canvas.zoomScale - fitWidth) < 0.001)

        // You can zoom out past a whole page, so the floor is strictly below
        // the scale at which one full initial page fits (`DataContract.md` §7).
        let fitInitialPage = min(fitWidth, root.frame.height / PageGeometry.initialHeight)
        #expect(canvas.minimumZoomScale < fitInitialPage)
        #expect(canvas.minimumZoomScale > 0)
        #expect(canvas.maximumZoomScale > canvas.zoomScale)

        // A repeated layout pass must not reset the viewport.
        canvas.zoomScale = canvas.minimumZoomScale * 2
        let zoomed = canvas.zoomScale
        root.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(canvas.zoomScale == zoomed)

        // The canvas starts empty.
        //
        // Undo is deliberately not asserted here: `undoManager` walks the
        // responder chain, so an unhosted controller always reports nil. Undo
        // and redo are device-verified behavior, not a unit-testable property.
        #expect(canvas.drawing.strokes.isEmpty)
    }

    @Test("A whole page fits on screen at minimum zoom, however tall the page grows")
    func wholePageFitsAtMinimumZoom() {
        let controller = PageCanvasController()
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let floor = canvas.minimumZoomScale

        // The reported complaint: at the floor you could not see a whole page.
        #expect(PageGeometry.width * floor <= root.frame.width)
        #expect(PageGeometry.initialHeight * floor <= root.frame.height)

        // And extending must not move the floor, or every extension would
        // shrink the canvas a little further.
        controller.setPageHeight(PageGeometry.initialHeight * 6)
        root.layoutIfNeeded()
        #expect(canvas.minimumZoomScale == floor)
    }

    @Test("Ink stays in page space through zoom and pan")
    func inkIsAuthoredInPageSpace() {
        let controller = PageCanvasController()
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        canvas.drawing = strokeAcrossPage()
        let authored = canvas.drawing.bounds

        // The whole viewport range: minimum zoom, maximum zoom, back to fit,
        // and a pan to a far corner.
        canvas.zoomScale = canvas.minimumZoomScale
        canvas.zoomScale = canvas.maximumZoomScale
        canvas.contentOffset = CGPoint(x: canvas.contentSize.width, y: canvas.contentSize.height)
        root.layoutIfNeeded()
        canvas.zoomScale = canvas.minimumZoomScale

        // Page-space geometry is durable truth; viewport state is not.
        #expect(canvas.drawing.bounds == authored)
        #expect(canvas.drawing.strokes.count == 1)
    }

    /// When PencilKit reports a programmatic assignment to `drawing`.
    ///
    /// This asserts a property of the framework, not of this app, and it is
    /// load-bearing: a suppression flag set and cleared inside one synchronous
    /// scope can only suppress a *synchronous* callback. If PencilKit posted the
    /// change later, such a flag would always read false by the time the
    /// callback arrived and would suppress nothing, leaving the real protection
    /// somewhere else entirely. The answer decides which single mechanism
    /// prevents a load from marking the document dirty.
    @Test("PencilKit reports a programmatic drawing assignment synchronously")
    func drawingChangeDeliveryIsSynchronous() async throws {
        let controller = PageCanvasController()
        var deliveries = 0
        controller.onDrawingChanged = { deliveries += 1 }

        controller.canvasView.drawing = strokeAcrossPage()
        let duringAssignment = deliveries

        // Give an asynchronous delivery every chance to arrive: main-actor
        // reentrancy, then a run-loop turn's worth of real time.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))

        #expect(deliveries >= 1, "PencilKit never reported the assignment at all")
        #expect(
            duringAssignment == deliveries,
            "delivery is asynchronous: \(duringAssignment) callback(s) during the assignment, \(deliveries) once the main actor drained"
        )
    }

    @Test("A copied drawing snapshot serializes without consulting the live canvas")
    func drawingSnapshotIsIndependent() async throws {
        let controller = PageCanvasController()
        controller.canvasView.drawing = strokeAcrossPage()
        let snapshot = controller.drawingSnapshot()

        controller.canvasView.drawing = PKDrawing()

        let restored = try PKDrawing(data: await snapshot.serialized().data)
        #expect(restored.strokes.count == 1)
        #expect(restored.bounds == strokeAcrossPage().bounds)
        #expect(controller.canvasView.drawing.strokes.isEmpty)
    }

    /// A stroke at known page-space coordinates, well inside the page bounds.
    private func strokeAcrossPage() -> PKDrawing {
        let locations = [
            CGPoint(x: 100, y: 150),
            CGPoint(x: 300, y: 400),
            CGPoint(x: 500, y: 650),
        ]
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    private func pkCanvasViews(in root: UIView) -> [PKCanvasView] {
        var found: [PKCanvasView] = []
        if let canvas = root as? PKCanvasView { found.append(canvas) }
        for subview in root.subviews { found.append(contentsOf: pkCanvasViews(in: subview)) }
        return found
    }
}

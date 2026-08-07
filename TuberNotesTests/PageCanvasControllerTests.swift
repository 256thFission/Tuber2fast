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
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
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
        #expect(abs(unscaled.width - PageGeometry.canonical.width) < 0.5)
        #expect(abs(unscaled.height - PageGeometry.canonical.height) < 0.5)

        // The opening scale fits the page width — the scale to write at.
        let fitWidth = root.frame.width / PageGeometry.canonical.width
        #expect(abs(canvas.zoomScale - fitWidth) < 0.001)

        // You can zoom out past a whole page, so the floor is strictly below
        // the scale at which one full page fits
        // (`Contract.md` — Geometry and coordinates).
        let fitPage = min(fitWidth, root.frame.height / PageGeometry.canonical.height)
        #expect(canvas.minimumZoomScale < fitPage)
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

    @Test("A whole page fits on screen at minimum zoom")
    func wholePageFitsAtMinimumZoom() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let floor = canvas.minimumZoomScale

        // The reported complaint: at the floor you could not see a whole page.
        #expect(PageGeometry.canonical.width * floor <= root.frame.width)
        #expect(PageGeometry.canonical.height * floor <= root.frame.height)

        // A repeated layout pass must not move the floor.
        root.layoutIfNeeded()
        #expect(canvas.minimumZoomScale == floor)
    }

    /// The canvas renders **the geometry it is given**, not a global. A
    /// landscape page is a landscape page: its content size is its own, and so
    /// is its zoom floor.
    @Test("A canvas built for a landscape page is landscape, floor and all")
    func landscapePageIsLandscape() {
        let landscape = PageGeometry(width: 842, height: 595)
        let controller = PageCanvasController(
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: landscape,
                zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
            )
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let unscaled = CGSize(
            width: canvas.contentSize.width / canvas.zoomScale,
            height: canvas.contentSize.height / canvas.zoomScale
        )
        #expect(abs(Double(unscaled.width) - landscape.width) < 0.5)
        #expect(abs(Double(unscaled.height) - landscape.height) < 0.5)

        // It opens at *its own* fit-width, and the whole of it fits at the
        // floor — the floor derives from the page it belongs to.
        #expect(abs(Double(canvas.zoomScale) - 820 / landscape.width) < 0.001)
        #expect(landscape.width * Double(canvas.minimumZoomScale) <= 820)
        #expect(landscape.height * Double(canvas.minimumZoomScale) <= 1180)
    }

    /// Two pages of different sizes, side by side in the same document, each
    /// reading only its own geometry. This is the mixed run an annotated import
    /// is: a landscape worksheet and the blank canonical page appended after it.
    @Test("Neighbouring pages of different geometry get different floors and the same ceiling")
    func mixedGeometryNeighboursDoNotShareAFloor() {
        let portrait = hostedCanvas(geometry: .canonical)
        let landscape = hostedCanvas(geometry: PageGeometry(width: 842, height: 595))

        // Different pages, different floors — nothing global is being read.
        #expect(portrait.minimumZoomScale != landscape.minimumZoomScale)
        #expect(PageGeometry.canonical.height * Double(portrait.minimumZoomScale) <= 1180)
        #expect(595 * Double(landscape.minimumZoomScale) <= 1180)

        // Same document, same ceiling: the cap is a document constant and owes
        // nothing to either page's size.
        #expect(portrait.maximumZoomScale == landscape.maximumZoomScale)
    }

    /// A9, in the form a test can fail on. The ceiling used to be `fitWidth × 8`
    /// — a function of the viewport, so it moved with the device, the rotation,
    /// and Split View. Now the same document reaches the same maximum scale in
    /// every viewport, and one device pixel represents exactly the durable cap's
    /// worth of page points there.
    @Test("The zoom ceiling is the durable cap and does not move with the viewport")
    func zoomCeilingIsDurableAndViewportIndependent() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        let canvas = controller.canvasView
        let portraitCeiling = canvas.maximumZoomScale

        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.layoutIfNeeded()
        #expect(canvas.maximumZoomScale == portraitCeiling)

        // A Split View third of the screen: a viewport a third the size used to
        // mean a third the maximum detail.
        root.frame = CGRect(x: 0, y: 0, width: 393, height: 1180)
        root.layoutIfNeeded()
        #expect(canvas.maximumZoomScale == portraitCeiling)

        // And the ceiling means what the cap says it means.
        let displayScale = Double(max(controller.traitCollection.displayScale, 1))
        let pagePointsPerPixel = 1 / (Double(portraitCeiling) * displayScale)
        #expect(abs(pagePointsPerPixel - DocumentIndex.canonicalZoomCapPagePointsPerPixel) < 1e-9)
    }

    /// A document whose cap says "deeper" gets a deeper ceiling, on the same
    /// device and the same page. The cap is durable per document, so it is the
    /// document that decides.
    @Test("A document's own cap decides its ceiling")
    func documentCapDecidesTheCeiling() {
        let shallow = hostedCanvas(geometry: .canonical, zoomCap: 1.0 / 5.0)
        let deep = hostedCanvas(geometry: .canonical, zoomCap: 1.0 / 20.0)

        #expect(deep.maximumZoomScale > shallow.maximumZoomScale)
        #expect(abs(Double(deep.maximumZoomScale / shallow.maximumZoomScale) - 4) < 1e-6)
    }

    /// The framework limit that bounds the durable cap, asserted where it
    /// bites. `PKCanvasView` refuses a `maximumZoomScale` above 10 and says
    /// nothing; a plain `UIScrollView` keeps whatever it is given. The canonical
    /// cap is chosen to sit exactly at that limit at a display scale of 2, and
    /// this is the measurement that justifies the number.
    @Test("PKCanvasView refuses a maximum zoom scale above ten, silently")
    func pencilKitClampsTheMaximumZoomScale() {
        for requested in [9.0, 10.0, 11.0, 20.0, 100.0] {
            let canvas = PKCanvasView()
            let plain = UIScrollView()
            canvas.maximumZoomScale = CGFloat(requested)
            plain.maximumZoomScale = CGFloat(requested)

            #expect(Double(plain.maximumZoomScale) == requested)
            #expect(
                Double(canvas.maximumZoomScale)
                    == min(requested, PageProjection.runtimeMaximumZoomScale)
            )
        }
    }

    @Test("A viewport resize re-fits the zoom range and keeps the user's scale")
    func viewportResizeReestablishesZoomRange() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let portraitFitWidth = 820 / PageGeometry.canonical.width

        // The user zooms to twice the scale the page opened at.
        canvas.zoomScale = portraitFitWidth * 2

        // Rotate: a different viewport, not a repeated layout pass.
        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.layoutIfNeeded()

        // The floor now describes the screen that exists, so a whole page still
        // fits at minimum zoom.
        #expect(PageGeometry.canonical.width * canvas.minimumZoomScale <= 1180)
        #expect(PageGeometry.canonical.height * canvas.minimumZoomScale <= 820)

        // And the user's zoom survives as a ratio of fit-width rather than
        // snapping back to fit.
        let landscapeFitWidth = 1180 / PageGeometry.canonical.width
        #expect(abs(canvas.zoomScale - landscapeFitWidth * 2) < 0.001)
    }

    @Test("A page smaller than the viewport is centred in it")
    func pageIsCentredWhenSmallerThanViewport() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView

        // At the floor the whole page fits with room to spare in both axes, so
        // the leftover room must fall evenly on both sides.
        canvas.zoomScale = canvas.minimumZoomScale
        root.layoutIfNeeded()

        let expectedHorizontal = (canvas.bounds.width - canvas.contentSize.width) / 2
        let expectedVertical = (canvas.bounds.height - canvas.contentSize.height) / 2
        #expect(expectedHorizontal > 0)
        #expect(expectedVertical > 0)
        #expect(abs(canvas.contentInset.left - expectedHorizontal) < 0.5)
        #expect(canvas.contentInset.left == canvas.contentInset.right)
        #expect(abs(canvas.contentInset.top - expectedVertical) < 0.5)
        #expect(canvas.contentInset.top == canvas.contentInset.bottom)

        // Filling the viewport horizontally leaves no horizontal room to give.
        canvas.zoomScale = canvas.maximumZoomScale
        root.layoutIfNeeded()
        #expect(canvas.contentInset.left == 0)
        #expect(canvas.contentInset.top == 0)
    }

    @Test("Ink stays in page space through zoom and pan")
    func inkIsAuthoredInPageSpace() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
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
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
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
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        controller.canvasView.drawing = strokeAcrossPage()
        let snapshot = controller.drawingSnapshot()

        controller.canvasView.drawing = PKDrawing()

        let restored = try PKDrawing(data: await snapshot.serialized().data)
        #expect(restored.strokes.count == 1)
        #expect(restored.bounds == strokeAcrossPage().bounds)
        #expect(controller.canvasView.drawing.strokes.isEmpty)
    }

    /// A laid-out canvas for one page's geometry, in a portrait viewport.
    private func hostedCanvas(
        geometry: PageGeometry,
        zoomCap: Double = DocumentIndex.canonicalZoomCapPagePointsPerPixel
    ) -> PKCanvasView {
        let controller = PageCanvasController(
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: geometry,
                zoomCapPagePointsPerPixel: zoomCap
            )
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        return controller.canvasView
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

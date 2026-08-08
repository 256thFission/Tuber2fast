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

        // The floor is fit-width: you may never zoom out to where horizontal
        // dead space appears beside the page (maintainer verdict, device
        // session 2026-08-07).
        #expect(abs(canvas.minimumZoomScale - fitWidth) < 0.001)
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

    /// The maintainer's verdict from the 2026-08-07 device session: the floor
    /// is fit-width, never lower. A landscape viewport is where the old
    /// fit-page floor diverged most — this test fails against that floor.
    @Test("The zoom floor is fit-width: no horizontal dead space, and vertical pan room remains")
    func zoomFloorIsFitWidth() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let fitWidth = root.frame.width / PageGeometry.canonical.width
        let floor = canvas.minimumZoomScale
        #expect(abs(floor - fitWidth) < 0.001)

        // At the floor the page exactly fills the viewport's width — no dead
        // space beside the page — and a portrait page is taller than the
        // viewport, so vertical panning within the page still has room.
        canvas.zoomScale = floor
        root.layoutIfNeeded()
        #expect(abs(canvas.contentSize.width - root.frame.width) < 0.5)
        #expect(canvas.contentSize.height > canvas.bounds.height)
        #expect(canvas.contentInset.left == 0)
        #expect(canvas.contentInset.right == 0)

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

        // It opens at *its own* fit-width, and that is also its floor — the
        // floor derives from the page it belongs to.
        #expect(abs(Double(canvas.zoomScale) - 820 / landscape.width) < 0.001)
        #expect(abs(Double(canvas.minimumZoomScale) - 820 / landscape.width) < 0.001)
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

        // The floor now describes the screen that exists: fit-width for the
        // rotated viewport, so no dead space can appear beside the page.
        #expect(abs(canvas.minimumZoomScale - 1180 / PageGeometry.canonical.width) < 0.001)

        // And the user's zoom survives as a ratio of fit-width rather than
        // snapping back to fit.
        let landscapeFitWidth = 1180 / PageGeometry.canonical.width
        #expect(abs(canvas.zoomScale - landscapeFitWidth * 2) < 0.001)
    }

    @Test("A page shorter than the viewport is centred vertically; fit-width leaves no horizontal room")
    func pageIsCentredWhenSmallerThanViewport() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView

        // At the fit-width floor the page exactly fills the width, so there is
        // never horizontal room to give; in this viewport the canonical page is
        // shorter than the screen at that scale, and the vertical leftover must
        // fall evenly on both sides.
        canvas.zoomScale = canvas.minimumZoomScale
        root.layoutIfNeeded()

        let expectedVertical = (canvas.bounds.height - canvas.contentSize.height) / 2
        #expect(expectedVertical > 0)
        // Fit-width fills the width to rounding error, so the horizontal
        // inset is zero to the same rounding error, never a visible band.
        #expect(abs(canvas.contentInset.left) < 0.01)
        #expect(abs(canvas.contentInset.right) < 0.01)
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

    /// The clamp for hardware outside the supported pixel grid, in the form a
    /// test can fail on. At a display scale of 1 — a trait collection not yet
    /// attached, or a 1x external screen — the canonical cap asks for a zoom
    /// scale of 20, which PKCanvasView silently refuses; the runtime clamps to
    /// what the canvas delivers instead of trapping, because the durable cap
    /// is validated against 2x hardware and a coarser display is outside that
    /// promise, not a violation of it.
    @Test("A display below the supported scale clamps the zoom ceiling instead of trapping")
    func subMinimumDisplayScaleClampsInsteadOfTrapping() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        controller.traitOverrides.displayScale = 1
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        #expect(Double(canvas.maximumZoomScale) == PageProjection.runtimeMaximumZoomScale)
        #expect(canvas.maximumZoomScale > canvas.minimumZoomScale)
        #expect(canvas.zoomScale <= canvas.maximumZoomScale)
    }

    // MARK: - Selection feeding the composite

    @Test("Selection feeds the composite request: minus the selected layer, back in on deselect")
    func selectionFeedsTheCompositeRequest() async throws {
        let store = try scratchStore()
        let first = try await imageLayer(
            store: store, color: .red,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 50)
        )
        let second = try await imageLayer(
            store: store, color: .green,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 400)
        )

        let controller = PageCanvasController(
            toolPicker: PKToolPicker(), projection: .canonical,
            staticRenderer: StaticLayerRenderer(store: store)
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([first, second])
        root.layoutIfNeeded()

        let full = try #require(controller.renderedRequestForTesting)
        #expect(full.layers.map(\.layerID) == [first.layerID, second.layerID])

        let selection = try #require(controller.selection)
        selection.select(first)
        // The exclusion may only follow the lift, so the request changes once
        // the selected layer's source has decoded.
        try await waitUntil("the composite request excludes the selected layer") {
            controller.renderedRequestForTesting?.layers.map(\.layerID) == [second.layerID]
        }

        selection.select(nil)
        try await waitUntil("deselection re-includes the layer") {
            controller.renderedRequestForTesting?.layers.map(\.layerID) == [first.layerID, second.layerID]
        }
    }

    @Test("Switching selection A to B never leaves A unrepresented")
    func switchingSelectionHoldsTheHandover() async throws {
        let store = try scratchStore()
        let a = try await imageLayer(
            store: store, color: .red,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 50)
        )
        let b = try await imageLayer(
            store: store, color: .green,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 400)
        )

        let renderer = StaticLayerRenderer(store: store)
        let controller = PageCanvasController(
            toolPicker: PKToolPicker(), projection: .canonical,
            staticRenderer: renderer
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([a, b])
        root.layoutIfNeeded()

        let backdrop = try #require(controller.backdrop)
        let page = backdrop.pageLayerForTesting
        let liftLayer = backdrop.liftLayerForTesting

        try await waitUntil("the full composite lands") { page.contents != nil }
        let fullContents = contents(of: page)

        let selection = try #require(controller.selection)
        selection.select(a)
        try await waitUntil("A lifts") { backdrop.hasLift }
        try await waitUntil("the minus-A composite lands") { self.contents(of: page) !== fullContents }
        let minusA = contents(of: page)
        let liftA = contents(of: liftLayer)
        #expect(liftA != nil)

        // Hold the next composite — the one that re-includes A — in flight,
        // so the handover window is a state the test can inspect rather than
        // a race it hopes to lose.
        let hold = CompositeHold()
        await renderer.setRenderGateForTesting { _ in await hold.wait() }

        selection.select(b)
        // B's source has decoded once the controller asks for the minus-B
        // composite; the request seam is how the test knows it happened.
        try await waitUntil("the minus-B composite is requested") {
            controller.renderedRequestForTesting?.layers.map(\.layerID) == [a.layerID]
        }

        // The vanish window this test refuses: while the composite on screen
        // still excludes A, the lift must still be drawing A — swapping it to
        // B here would leave A in neither the composite nor the lift.
        #expect(
            contents(of: liftLayer) === liftA,
            "the lift swapped to B while the composite on screen still excludes A"
        )
        #expect(contents(of: page) === minusA)

        await hold.open()
        try await waitUntil("the lift swaps to B") { self.contents(of: liftLayer) !== liftA }
        #expect(
            contents(of: page) !== minusA,
            "the swap must land with the composite that re-includes A, never before it"
        )
    }

    /// Blocks every gated render until opened. Late waiters pass through once
    /// opened.
    private actor CompositeHold {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    // MARK: - Static-layer helpers

    /// `CALayer.contents` as an identity, or nil. `Any?` cannot be compared
    /// with `!==` directly.
    private func contents(of layer: CALayer) -> AnyObject? {
        guard let contents = layer.contents else { return nil }
        return contents as AnyObject
    }

    /// A store over a unique scratch directory, the same shape as
    /// `StaticLayerRenderTests` uses.
    private func scratchStore() throws -> DocumentStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tubernotes-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("JustACanvas.tubernotes/pages"),
            withIntermediateDirectories: true
        )
        return DocumentStore(directoryURL: root.appendingPathComponent("JustACanvas.tubernotes"))
    }

    /// Writes a solid HEIC asset and returns the layer envelope naming it.
    private func imageLayer(
        store: DocumentStore,
        color: UIColor,
        transform: PageSpaceTransform
    ) async throws -> LayerEnvelope {
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        guard
            let cgImage = drawn.cgImage,
            let bytes = ImageImportPreparation.heicEncoded(cgImage)
        else {
            preconditionFailure("HEIC encoding failed")
        }
        let assetID = UUID()
        try await store.writeAsset(bytes, assetID: assetID, format: .heic)
        return try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: transform
        )
    }

    /// Polls until `condition` holds, or fails after a second.
    private func waitUntil(
        _ what: String,
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
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

import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberRender
@testable import TuberStore
import UIKit

/// Configuration invariants of a canvas runtime.
@Suite("Canvas runtime", .serialized)
@MainActor
struct PageCanvasControllerTests {
    @Test("The canvas owner configures page space, input policy, and fit zoom")
    func canvasInvariants() {
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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

        // The floor is fit-page, and in a portrait viewport that min *is*
        // fit-width: no horizontal dead space beside the page (maintainer
        // verdict, device session 2026-08-07 — upheld in portrait when the
        // 2026-08-08 landscape verdict moved the floor to fit-page).
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

    /// Two maintainer verdicts, one from each orientation, and the fit-page
    /// floor is the min that honors both. Portrait 2026-08-07: no dead space
    /// beside the page — there fit-width *is* the min, and `canvasInvariants`
    /// holds it. Landscape 2026-08-08: a fit-width floor left the page's full
    /// extent unreachable, so the floor is the whole page and the side room
    /// centres. This test fails against the fit-width floor it replaces.
    @Test("The zoom floor is fit-page: a landscape viewport can pull back to the whole page, centred")
    func zoomFloorIsFitPageInLandscape() {
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.layoutIfNeeded()

        let canvas = controller.canvasView
        let fitPage = root.frame.height / PageGeometry.canonical.height

        // The page opens at the floor: its full extent on screen, top and
        // bottom, never dropped into the middle of a page not yet seen
        // (device verdict, 2026-08-08). Zooming in to write is the user's
        // pinch.
        #expect(abs(canvas.zoomScale - fitPage) < 0.001)
        // The floor is the whole page, which in landscape is fit-height.
        let floor = canvas.minimumZoomScale
        #expect(abs(floor - fitPage) < 0.001)

        // At the floor the whole page is visible — full height, nothing to
        // pan — and the side room splits evenly rather than pinning the page
        // to the leading edge.
        canvas.zoomScale = floor
        root.layoutIfNeeded()
        #expect(abs(canvas.contentSize.height - root.frame.height) < 0.5)
        #expect(canvas.contentSize.width < root.frame.width)
        #expect(canvas.contentInset.left > 0)
        #expect(abs(canvas.contentInset.left - canvas.contentInset.right) < 0.5)

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
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: landscape,
                zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
            ),
            host: TestPageHost()
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
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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

        // The floor now describes the screen that exists: fit-page for the
        // rotated viewport, which in landscape is fit-height — the whole page
        // stays reachable (device verdict, 2026-08-08).
        let landscapeFitPage = 820 / PageGeometry.canonical.height
        #expect(abs(canvas.minimumZoomScale - landscapeFitPage) < 0.001)

        // And the user's zoom survives as a ratio of the floor rather than
        // snapping back to fit: twice fit-page before the rotation is twice
        // fit-page after it. (In the portrait viewport fit-page and fit-width
        // coincide for this page, so the 2× above was a ratio of both.)
        #expect(abs(canvas.zoomScale - landscapeFitPage * 2) < 0.001)
    }

    @Test("A page shorter than the viewport is centred vertically; fit-width leaves no horizontal room")
    func pageIsCentredWhenSmallerThanViewport() {
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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

    /// The other half of the same rule, and the half that is this app's:
    /// installing a page's ink is never reported as an edit
    /// (`Contract.md` — Lifecycle). A canvas now reports to a host it cannot
    /// be built without, so the report can no longer be avoided by wiring it
    /// late; `installDrawing` detaches the delegate across the assignment
    /// instead, and this is what says so.
    @Test("Installing a page's ink is not reported as a drawing change")
    func installingInkIsNotReportedAsAnEdit() {
        let host = TestPageHost()
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: host
        )
        _ = controller.view

        controller.installDrawing(from: DrawingSnapshot(drawing: strokeAcrossPage()))

        #expect(controller.canvasView.drawing.strokes.count == 1)
        #expect(host.drawingChanges == 0)

        // And the canvas is still reporting: the delegate came back.
        controller.canvasView.drawing = strokeAcrossPage()
        #expect(host.drawingChanges == 1)
    }

    /// When PencilKit reports a programmatic assignment to `drawing`.
    ///
    /// This asserts a property of the framework, not of this app, and it is
    /// load-bearing: detaching the delegate across one synchronous assignment
    /// — which is what `installDrawing` does, and the single mechanism that
    /// keeps a load from marking the document dirty — can only suppress a
    /// *synchronous* callback. If PencilKit posted the change later, the report
    /// would arrive with the delegate back in place and suppress nothing,
    /// leaving the real protection somewhere else entirely.
    @Test("PencilKit reports a programmatic drawing assignment synchronously")
    func drawingChangeDeliveryIsSynchronous() async throws {
        var deliveries = 0
        let host = TestPageHost()
        host.onDrawingChanged = { deliveries += 1 }
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: host
        )

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
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: .canonical,
            host: TestPageHost()
        )
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
            pageID: UUID(),
            toolPicker: PKToolPicker(), projection: .canonical,
            host: TestPageHost(),
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
            pageID: UUID(),
            toolPicker: PKToolPicker(), projection: .canonical,
            host: TestPageHost(),
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

    @Test("A retired page's composite stops rather than finishing for nobody")
    func retirementCancelsTheCompositeInFlight() async throws {
        let store = try scratchStore()
        let layer = try await imageLayer(
            store: store, color: .red,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 50)
        )
        let renderer = StaticLayerRenderer(store: store)
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(), projection: .canonical,
            host: TestPageHost(),
            staticRenderer: renderer
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)

        // Hold the composite in flight, so retirement happens in the window
        // this test is about rather than in a race it hopes to win.
        let hold = CompositeHold()
        await renderer.setRenderGateForTesting { _ in await hold.wait() }

        controller.setStaticLayers([layer])
        root.layoutIfNeeded()
        try await waitUntilAsync("the composite is in flight") {
            await renderer.inFlightRenderCount == 1
        }

        // The user flicked past this page. Nothing it has in flight can ever
        // be installed again.
        controller.willRetire()
        // The slot going free is the positive signal that the cancellation
        // reached the renderer — what happens to the render *after* that is
        // `aSupersededRenderIsCancelled`'s half of this proof.
        try await waitUntilAsync("the abandoned render releases its slot") {
            await renderer.inFlightRenderCount == 0
        }

        await hold.open()
        let backdrop = try #require(controller.backdrop)
        #expect(
            await renderer.cachedCompositeCount == 0,
            "the decode a retired page asked for must stop, not run to completion and be cached"
        )
        #expect(contents(of: backdrop.pageLayerForTesting) == nil)
    }

    // MARK: - Paper, and what a blank page still pays

    @Test("A genuinely blank page builds no backdrop, keeps its opaque canvas, and asks for nothing")
    func aBlankPagePaysNothing() async throws {
        let controller = try templatedPage(.blank, layers: [])

        // `Docs/Unproven.md` cares about this property, so it is asserted
        // rather than assumed: the transparency and the sibling stack are paid
        // for **per page that has a stack**, and a page of a blank notebook on
        // blank paper is untouched by any of it.
        #expect(controller.backdrop == nil, "no layers and no paper is no sibling stack")
        #expect(controller.canvasView.isOpaque, "an opaque canvas is one fewer full-screen blend per frame")
        #expect(controller.canvasView.backgroundColor == .white, "and its background is still the page")
        #expect(controller.renderedRequestForTesting == nil, "nothing is composited for a page with no picture")
    }

    @Test("A templated page with no layers builds a backdrop and goes transparent")
    func ruledPaperCostsTheBackdrop() async throws {
        let controller = try templatedPage(.lined, layers: [])
        let backdrop = try #require(controller.backdrop, "ruled paper is a picture, and a picture needs the stack")
        #expect(controller.canvasView.isOpaque == false)

        let request = try #require(controller.renderedRequestForTesting)
        #expect(request.template == .lined)
        #expect(request.layers.isEmpty, "the paper is not a layer and never enters the list")
        try await waitUntil("the paper composites") { self.contents(of: backdrop.pageLayerForTesting) != nil }
    }

    @Test("Setting the template supersedes the composite, hides the lens, and re-requests")
    func settingTheTemplateRedrawsThePage() async throws {
        let controller = try templatedPage(.lined, layers: [], geometry: PageGeometry(width: 400, height: 400))
        let backdrop = try #require(controller.backdrop)
        let canvas = controller.canvasView
        try await waitUntil("the ruled paper lands") { self.contents(of: backdrop.pageLayerForTesting) != nil }
        let ruled = contents(of: backdrop.pageLayerForTesting)

        // A settled deep zoom, so there is a sharp patch on screen for the
        // change to invalidate.
        canvas.zoomScale = 4
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        try await waitUntil("the lens lands") { backdrop.hasLens }

        controller.setTemplate(.grid)

        // Synchronously, before any frame renders: the sharp patch describes
        // paper this page no longer has, and a wrong picture at the highest
        // sharpness is the worst thing this pipeline can show.
        #expect(backdrop.hasLens == false)
        let reissued = try #require(controller.renderedRequestForTesting)
        #expect(reissued.template == .grid, "the change re-requests immediately, not at the next layout pass")

        try await waitUntil("the new paper lands") {
            self.contents(of: backdrop.pageLayerForTesting) !== ruled
        }
        #expect(controller.canvasView.isOpaque == false, "still ruled, so still transparent")

        // Setting the same value again is a no-op, not a re-render.
        let settled = contents(of: backdrop.pageLayerForTesting)
        controller.setTemplate(.grid)
        #expect(contents(of: backdrop.pageLayerForTesting) === settled)
    }

    @Test("A ruled page asks for no composite and no lens from a gesture frame")
    func paperIsNeverRequestedFromAGestureFrame() async throws {
        let controller = try templatedPage(.lined, layers: [], geometry: PageGeometry(width: 400, height: 400))
        let canvas = controller.canvasView
        let asked = try #require(controller.renderedRequestForTesting)

        canvas.zoomScale = 4
        controller.scrollViewDidZoom(canvas)
        controller.scrollViewDidScroll(canvas)
        #expect(controller.lensRequestCountForTesting == 0, "a pinch decodes nothing, ruled or not")
        #expect(
            controller.renderedRequestForTesting == asked,
            "and re-composites nothing: the compositor scales the paper it already has"
        )

        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        #expect(controller.lensRequestCountForTesting == 1, "settle is the lens moment for paper too")
    }

    @Test("Deleting the last layer of a ruled page leaves the paper on it")
    func removingEveryLayerKeepsThePaper() async throws {
        let store = try scratchStore()
        let layer = try await imageLayer(
            store: store, color: .red,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 50, ty: 50)
        )
        let controller = try templatedPage(.lined, layers: [layer], store: store)
        #expect(controller.backdrop != nil)

        controller.setStaticLayers([])

        // The tear-down asks whether anything is left beneath the ink, not
        // whether the layer list is empty. Asking the narrower question would
        // rip the paper off the page the moment its last image was deleted.
        #expect(controller.backdrop != nil, "the paper is still a picture")
        #expect(controller.canvasView.isOpaque == false)
        let request = try #require(controller.renderedRequestForTesting)
        #expect(request.layers.isEmpty && request.template == .lined)

        // And blanking the paper too does take the whole stack down.
        controller.setTemplate(.blank)
        #expect(controller.backdrop == nil)
        #expect(controller.canvasView.isOpaque)
    }

    /// A laid-out page carrying a template and a layer list, with a real
    /// renderer behind it.
    private func templatedPage(
        _ template: PageTemplate,
        layers: [LayerEnvelope],
        geometry: PageGeometry = .canonical,
        store: DocumentStore? = nil
    ) throws -> PageCanvasController {
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: geometry,
                zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
            ),
            host: TestPageHost(),
            staticRenderer: StaticLayerRenderer(store: try store ?? scratchStore())
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        // The order `PagedCanvasController.makeCanvas` uses.
        controller.setStaticLayers(layers)
        controller.setTemplate(template)
        root.layoutIfNeeded()
        return controller
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

    /// `waitUntil` for a condition that has to ask an actor. Separately named
    /// rather than overloaded: an async closure and a synchronous one are
    /// ambiguous to overload resolution at every existing call site.
    private func waitUntilAsync(
        _ what: String,
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
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
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: geometry,
                zoomCapPagePointsPerPixel: zoomCap
            ),
            host: TestPageHost()
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

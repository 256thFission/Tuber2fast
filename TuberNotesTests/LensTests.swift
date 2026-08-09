import CoreGraphics
import ImageIO
import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberRender
import UIKit

/// Phase 3c, second deliverable: sharp content at zoom settle — the "lens" of
/// `Docs/Forks/CanvasFeatureComplete.md`'s base-and-lens design.
///
/// What is proven here is what the honest seams can prove off a device: that
/// no gesture frame ever asks for a lens and the settle callbacks do; that a
/// lens still in flight when the view moves on is dropped, never shown; that
/// the visible rect is clamped to the page before the rasterizer (which
/// refuses out-of-page sub-rects) ever sees it; that the lens pixels are
/// genuinely sharper than the scaled-up base at the same spot; and that an
/// image layer riding on a pdf page is present in the lens rather than hidden
/// under it.
///
/// What is **not** provable here and stays owed to device spike 2: whether
/// lens renders of dense vector pages arrive fast enough to feel right. The
/// latency number and the feel are Phillip's verdict on hardware.
@Suite("The lens: sharp content at zoom settle")
struct LensTests {

    /// The page every request in this suite is for. One document page, so two
    /// composites of it differ by level of detail or by layer list and never
    /// by identity — and the cache's page-scoped eviction has one page to be
    /// about.
    private static let pageID = UUID()

    /// The stripe fixture's page: 400 points square, so a viewport-sized test
    /// host reaches lens-worthy zooms inside PKCanvasView's own ceiling.
    private static let stripeGeometry = PageGeometry(width: 400, height: 400)

    // MARK: - The renderer's half

    @Test("The lens at depth resolves detail the scaled base cannot")
    func theLensIsSharperThanTheBase() async throws {
        let scratch = try TestScratch("lens")
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.stripePDF(side: 400),
            transform: PageSpaceTransform(a: 400, b: 0, c: 0, d: 400, tx: 0, ty: 0)
        )

        // The base at one pixel per page point: every pixel straddles half a
        // black and half a white stripe and lands mid-grey. This is what deep
        // zoom shows scaled up — soft by construction.
        let base = await renderer.composite(
            for: StaticLayerRequest(
                pageID: Self.pageID,
                layers: [layer],
                geometry: Self.stripeGeometry,
                template: .blank,
                pixelsPerPagePoint: 1
            )
        )
        guard case .composited(let soft) = base else {
            Issue.record("the base did not composite: \(base)")
            return
        }
        let basePixel = pixel(soft.image, x: 40, y: 40)
        #expect(
            basePixel.r > 60 && basePixel.r < 200,
            "at 1 px/pt the stripes must alias to grey (got \(basePixel)) or this fixture proves nothing"
        )

        // The lens over a quarter of the page at two pixels per page point:
        // pure black and pure white columns alternate.
        let render = await renderer.lens(
            for: StaticLayerRequest(
                pageID: Self.pageID,
                layers: [layer],
                geometry: Self.stripeGeometry,
                template: .blank,
                pixelsPerPagePoint: 2
            ),
            visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        guard case .composited(let sharp) = render else {
            Issue.record("the lens did not composite: \(render)")
            return
        }
        #expect(sharp.image.width == 200 && sharp.image.height == 200)
        let black = pixel(sharp.image, x: 40, y: 40)  // 40 px = 20 pt = stripe start
        let white = pixel(sharp.image, x: 41, y: 40)
        #expect(black.r < 40, "an even column at 2 px/pt is a whole stripe (got \(black))")
        #expect(white.r > 215, "an odd column at 2 px/pt is whole gap (got \(white))")
        #expect(sharp.builtOffMain, "the lens must render off the main thread")
    }

    @Test("The lens renders the rect it was asked about, not the page origin")
    func theLensIsTheVisibleRect() async throws {
        let scratch = try TestScratch("lens")
        let renderer = StaticLayerRenderer(store: scratch.store)
        // The quadrant fixture: distinct colors per region make "which rect"
        // observable.
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        let request = StaticLayerRequest(
            pageID: Self.pageID,
            layers: [layer], geometry: PageGeometry(width: 120, height: 200), template: .blank, pixelsPerPagePoint: 2
        )

        let render = await renderer.lens(
            for: request, visibleRect: CGRect(x: 60, y: 100, width: 60, height: 100)
        )
        guard case .composited(let lens) = render else {
            Issue.record("the lens did not composite: \(render)")
            return
        }
        // The bottom-right quadrant is solid yellow, wall to wall.
        #expect(isYellow(pixel(lens.image, x: 5, y: 5)))
        #expect(isYellow(pixel(lens.image, x: 114, y: 194)))
    }

    @Test("An image layer on a pdf page is present in the lens, above the worksheet")
    func anImageRidesInTheLens() async throws {
        let scratch = try TestScratch("lens")
        let renderer = StaticLayerRenderer(store: scratch.store)
        let worksheet = try await scratch.pdfLayer(
            bytes: PDFFixture.stripePDF(side: 400),
            transform: PageSpaceTransform(a: 400, b: 0, c: 0, d: 400, tx: 0, ty: 0)
        )
        let sticker = try await scratch.imageLayer(
            color: .green,
            transform: PageSpaceTransform(a: 20, b: 0, c: 0, d: 20, tx: 10, ty: 10)
        )

        let render = await renderer.lens(
            for: StaticLayerRequest(
                pageID: Self.pageID,
                layers: [worksheet, sticker], geometry: Self.stripeGeometry, template: .blank, pixelsPerPagePoint: 2
            ),
            visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        guard case .composited(let lens) = render else {
            Issue.record("the lens did not composite: \(render)")
            return
        }
        #expect(isGreen(pixel(lens.image, x: 40, y: 40)), "the image must not vanish under the lens")
        let stripes = pixel(lens.image, x: 80, y: 40)
        #expect(stripes.r < 40 || stripes.r > 215, "the worksheet around it is sharp")
    }

    @Test("A pdf layer partly outside the visible rect contributes its overlap only")
    func partialOverlapIsClipped() async throws {
        let scratch = try TestScratch("lens")
        let renderer = StaticLayerRenderer(store: scratch.store)
        // The quadrant source placed in the page's lower-right; the lens looks
        // at the upper-left, overlapping only the source's top-left (red).
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 60, ty: 80)
        )
        let render = await renderer.lens(
            for: StaticLayerRequest(
                pageID: Self.pageID,
                layers: [layer],
                geometry: .canonical,
                template: .blank,
                pixelsPerPagePoint: 2
            ),
            visibleRect: CGRect(x: 0, y: 0, width: 120, height: 160)
        )
        guard case .composited(let lens) = render else {
            Issue.record("the lens did not composite: \(render)")
            return
        }
        #expect(isWhite(pixel(lens.image, x: 40, y: 40)), "bare page where the layer is not")
        #expect(isRed(pixel(lens.image, x: 200, y: 240)), "the overlap shows the source's own region")
    }

    // MARK: - The controller's half: settle, staleness, clamping

    @Test("A gesture frame never requests a lens; the settle callbacks do")
    @MainActor
    func theLensIsAskedForAtSettleOnly() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let canvas = controller.canvasView

        canvas.zoomScale = 4
        controller.scrollViewDidZoom(canvas)
        controller.scrollViewDidScroll(canvas)
        #expect(controller.lensRequestCountForTesting == 0, "no decode is ever triggered by a gesture frame")

        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        #expect(controller.lensRequestCountForTesting == 1, "zoom settle is the lens moment")

        // A pan at depth settles too, both ways a drag can end.
        controller.scrollViewDidEndDecelerating(canvas)
        #expect(controller.lensRequestCountForTesting == 2)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        #expect(controller.lensRequestCountForTesting == 3)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        #expect(controller.lensRequestCountForTesting == 3, "a drag that will decelerate has not settled")
    }

    @Test("A settle at or near the base's own detail asks for nothing")
    @MainActor
    func aShallowSettleAsksForNothing() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let canvas = controller.canvasView
        // fit-width for a 400pt page in an 820pt viewport is ~2.05; the base
        // composite already carries that detail, so settling there is not a
        // lens moment.
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: canvas.zoomScale)
        #expect(controller.lensRequestCountForTesting == 0, "the base is already pixel-exact at fit-width")
    }

    @Test("The lens lands above the base and shows at the settled rect")
    @MainActor
    func theLensLands() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let canvas = controller.canvasView
        let backdrop = try #require(controller.backdrop)

        canvas.zoomScale = 4
        canvas.contentOffset = CGPoint(x: 400, y: 400)
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        let asked = try #require(controller.lensRequestForTesting)

        try await waitUntil("the lens lands") { backdrop.hasLens }
        let lens = backdrop.lensLayerForTesting
        #expect(lens.isHidden == false)
        #expect(lens.contents != nil)
        // Placed over exactly the rect that was asked about, in page points.
        #expect(Double(lens.position.x) == Double(asked.rect.minX))
        #expect(Double(lens.position.y) == Double(asked.rect.minY))
        #expect(Double(lens.bounds.width) == Double(asked.rect.width))
    }

    @Test("A stale lens is dropped: zooming again while one is in flight")
    @MainActor
    func aStaleLensIsDropped() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let renderer = hosted.renderer
        let canvas = controller.canvasView
        let backdrop = try #require(controller.backdrop)

        // Hold every render at the gate so the lens is deterministically in
        // flight when the user zooms again.
        let gate = Gate()
        await renderer.setRenderGateForTesting { await gate.wait($0) }

        canvas.zoomScale = 4
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        #expect(controller.lensRequestCountForTesting == 1)

        // The user pinches again before the lens lands: the in-flight lens
        // describes a state no longer on screen.
        controller.scrollViewDidZoom(canvas)
        await gate.releaseAll()

        // The render completes and must go nowhere.
        //
        // This wait stays wall-clock, and the reason is worth writing down
        // because every other timing wait in this suite was retired. What is
        // asserted here is a *non-event*: a delivery that never happens. There
        // is no positive signal to wait on — the renderer's actor goes free at
        // its first suspension, so a round-trip through it proves nothing
        // about the rasterization still running off-actor, and yielding the
        // main actor only runs work already enqueued on it. Both were tried
        // against a planted violation (the generation guard removed) and both
        // passed, which is the definition of decoration; this form fails.
        //
        // The window is therefore the assertion's only margin, in the
        // false-green direction alone: under enough load a dropped-guard build
        // could deliver after the check. Making it load-immune needs a
        // positive signal the delivery decision was made, and that is a
        // production observable this item is in the business of removing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(backdrop.hasLens == false, "a lens for a superseded settle must be dropped, not shown")
        #expect(backdrop.lensLayerForTesting.contents == nil)
    }

    @Test("The visible rect is clamped to the page before the rasterizer sees it")
    @MainActor
    func theVisibleRectIsClamped() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let canvas = controller.canvasView
        let backdrop = try #require(controller.backdrop)

        // A rubber-banded settle: negative offset puts the raw visible rect
        // partly outside the page, which the rasterizer would refuse.
        canvas.zoomScale = 4
        canvas.contentOffset = CGPoint(x: -80, y: -80)
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)

        let asked = try #require(controller.lensRequestForTesting)
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(pageRect.contains(asked.rect), "the request must already be clamped to the page")
        #expect(Double(asked.rect.minX) == 0 && Double(asked.rect.minY) == 0)

        // And the clamped request genuinely renders — no refusal reached the
        // rasterizer.
        try await waitUntil("the clamped lens lands") { backdrop.hasLens }
    }

    @Test("The moment the view transforms away, the lens is gone")
    @MainActor
    func theLensDiesOnTheFirstGestureFrame() async throws {
        let hosted = try await hostedStripePage()
        let controller = hosted.controller
        let canvas = controller.canvasView
        let backdrop = try #require(controller.backdrop)

        canvas.zoomScale = 4
        controller.scrollViewDidEndZooming(canvas, with: nil, atScale: 4)
        try await waitUntil("the lens lands") { backdrop.hasLens }

        // The first frame of the next gesture: the sharp patch must not
        // survive to be wrong.
        controller.scrollViewDidScroll(canvas)
        #expect(backdrop.hasLens == false)
        #expect(backdrop.lensLayerForTesting.contents == nil)
    }

    // MARK: - Helpers

    /// A hosted page carrying one full-page stripe pdf layer, laid out and
    /// with its base composite requested.
    @MainActor
    private func hostedStripePage() async throws -> HostedPage {
        let scratch = try TestScratch("lens")
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.stripePDF(side: 400),
            transform: PageSpaceTransform(a: 400, b: 0, c: 0, d: 400, tx: 0, ty: 0)
        )
        let controller = PageCanvasController(
            pageID: UUID(),
            toolPicker: PKToolPicker(),
            projection: PageProjection(
                geometry: Self.stripeGeometry,
                zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
            ),
            host: TestPageHost(),
            staticRenderer: renderer
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([layer])
        root.layoutIfNeeded()
        // The scratch travels with the page: its `deinit` removes the
        // document, and the renderer reads the pdf asset from it on every
        // lens render, so a scratch that died here would take the fixture
        // with it.
        return HostedPage(controller: controller, renderer: renderer, scratch: scratch)
    }

    /// A laid-out page and everything that has to outlive the call that built
    /// it.
    @MainActor
    private struct HostedPage {
        let controller: PageCanvasController
        let renderer: StaticLayerRenderer
        let scratch: TestScratch
    }

    /// Releases every waiter at once; order does not matter to these tests.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait(_ request: StaticLayerRequest) async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func releaseAll() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @MainActor
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

    // MARK: Pixels

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("could not build a one-pixel context")
            return (0, 0, 0)
        }
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func near(_ value: Int, _ target: Int) -> Bool { abs(value - target) <= 12 }
    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 0) && near(p.b, 0)
    }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 255) && near(p.b, 0)
    }
    private func isYellow(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 0)
    }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 255)
    }
}

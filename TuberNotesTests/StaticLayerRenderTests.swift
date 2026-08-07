import CoreGraphics
import ImageIO
import PencilKit
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import TuberNotes

/// Phase 2 of `Docs/Forks/CanvasFeatureComplete.md`, rendering half: an `image`
/// layer visible under the ink.
///
/// What is proven here is what is mechanically provable off a device — the
/// composite's stacking order and orientation, that a decode is bounded by
/// where the layer lands rather than by the source, that the cache evicts on
/// its stated byte bound and on the live window, that a layer which will not
/// decode refuses the *whole* composite, and that none of it runs on the main
/// thread.
///
/// What is **not** provable here, and belongs to `Docs/Unproven.md`: whether
/// the sibling mirror holds registration with ink at 120 Hz through pinch,
/// fling, and rubber-band, and what a transparent `PKCanvasView` actually costs
/// in overdraw. The mirror arithmetic below is asserted; the *feel* of it is
/// device evidence and Phillip's verdict.
@Suite("Static layer rendering")
struct StaticLayerRenderTests {

    // MARK: - The composite

    @Test("The composite stacks layers in list order, lower ones beneath")
    func compositeStacksInListOrder() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        let whole = try await scratch.imageLayer(
            store: store,
            color: .red,
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
            )
        )
        // The top half of the page only, so "which one is on top" and "which
        // way up is the page" are both observable in one composite.
        let topHalf = try await scratch.imageLayer(
            store: store,
            color: .green,
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height / 2, tx: 0, ty: 0
            )
        )

        let above = try await composited(renderer, layers: [whole, topHalf])
        #expect(isGreen(pixel(above.image, x: 306, y: 100)), "the later layer must be on top")
        #expect(isRed(pixel(above.image, x: 306, y: 700)), "the earlier layer must show where the later one does not")

        // The same two layers in the other order: the full-page one is now
        // last, so it covers everything.
        let below = try await composited(renderer, layers: [topHalf, whole])
        #expect(isRed(pixel(below.image, x: 306, y: 100)))
        #expect(isRed(pixel(below.image, x: 306, y: 700)))
    }

    @Test("An image lands the right way up in page space")
    func imagesAreNotFlipped() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        // The source's own top half is blue. Page space is y-down from the
        // top-left and CoreGraphics is y-up from the bottom-left, so a missing
        // flip anywhere in the chain shows here as an upside-down page.
        let layer = try await scratch.imageLayer(
            store: store,
            image: Scratch.twoTonePNG(top: .blue, bottom: .yellow),
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
            )
        )

        let composite = try await composited(renderer, layers: [layer])
        #expect(isBlue(pixel(composite.image, x: 306, y: 60)), "the source's top must be the page's top")
        #expect(isYellow(pixel(composite.image, x: 306, y: 740)))
    }

    @Test("A layer is placed by its own transform, not stretched to the page")
    func placementFollowsTheTransform() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        // A 200x100 patch at (100, 200).
        let layer = try await scratch.imageLayer(
            store: store,
            color: .green,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        )

        let composite = try await composited(renderer, layers: [layer])
        #expect(isGreen(pixel(composite.image, x: 150, y: 250)), "inside the placed rect")
        #expect(isWhite(pixel(composite.image, x: 150, y: 150)), "above it is bare page")
        #expect(isWhite(pixel(composite.image, x: 400, y: 250)), "beside it is bare page")
        #expect(isWhite(pixel(composite.image, x: 150, y: 400)), "below it is bare page")
    }

    @Test("A page with no static layers renders nothing at all")
    func noLayersIsNotAComposite() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: [], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .empty = render else {
            Issue.record("an empty layer list rendered as \(render)")
            return
        }
        #expect(await renderer.cachedCompositeCount == 0, "nothing to render is nothing to cache")
    }

    // MARK: - Decode for the viewport, never for the source

    @Test("Downsampling decodes no larger than the bound it is given")
    func downsamplingHonoursItsBound() throws {
        let source = Scratch.solidPNG(width: 1600, height: 1000, color: .red)

        // The source, undiminished, for a comparison the assertion below needs.
        let full = try #require(StaticLayerRenderer.downsample(source, maxPixelSize: 4000))
        #expect(full.width == 1600 && full.height == 1000)

        for bound in [64, 200, 512] {
            let thumbnail = try #require(StaticLayerRenderer.downsample(source, maxPixelSize: bound))
            #expect(
                max(thumbnail.width, thumbnail.height) <= bound,
                "a bound of \(bound) produced \(thumbnail.width)x\(thumbnail.height)"
            )
            #expect(thumbnail.width > 0 && thumbnail.height > 0)
            #expect(
                thumbnail.width < full.width,
                "the bound must actually shrink the decode, not decode-then-scale"
            )
            // Aspect preserved, so the placement transform still means what it
            // says about the image's own extent.
            #expect(abs(Double(thumbnail.width) / Double(thumbnail.height) - 1.6) < 0.05)
        }
    }

    @Test("The decode bound is where the layer lands, at the level of detail asked for")
    func theDecodeBoundIsThePlacedExtent() {
        // A quarter-page-wide patch at one composite pixel per page point.
        let quarter = PageSpaceTransform(a: 150, b: 0, c: 0, d: 90, tx: 0, ty: 0)
        #expect(StaticLayerRenderer.maxPixelSize(of: quarter, at: 1) == 150)
        #expect(StaticLayerRenderer.maxPixelSize(of: quarter, at: 3) == 450)

        // Rotation does not change how many pixels of source can be seen: the
        // transform's columns are the placed edges whatever their direction.
        let rotated = PageSpaceTransform(a: 0, b: 150, c: -90, d: 0, tx: 0, ty: 0)
        #expect(StaticLayerRenderer.maxPixelSize(of: rotated, at: 1) == 150)

        // A layer smaller than one composite pixel still asks for one: a
        // zero-pixel thumbnail is meaningless, and a tiny placement is a legal
        // state rather than an invalid one.
        let tiny = PageSpaceTransform(a: 0.2, b: 0, c: 0, d: 0.2, tx: 0, ty: 0)
        #expect(StaticLayerRenderer.maxPixelSize(of: tiny, at: 1) == 1)
    }

    @Test("A large source placed small never materializes at full size")
    func aLargeSourcePlacedSmallDecodesSmall() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        // 1600x1000 of source, placed 60 page points wide.
        let layer = try await scratch.imageLayer(
            store: store,
            image: Scratch.solidPNG(width: 1600, height: 1000, color: .red),
            transform: PageSpaceTransform(a: 60, b: 0, c: 0, d: 37.5, tx: 10, ty: 10)
        )
        let request = StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 2)
        let bound = StaticLayerRenderer.maxPixelSize(of: layer.pageSpaceTransform, at: 2)
        #expect(bound == 120, "the decode is bounded by the placement, not by the source")

        // And the composite still lands: the bound is a real decode path, not a
        // calculation nothing uses.
        _ = try await composited(renderer, request: request)
        let decoded = try #require(
            StaticLayerRenderer.downsample(
                try await store.loadAsset(
                    assetID: try ImageLayerRef(payload: layer.payload).assetID,
                    format: .png
                ),
                maxPixelSize: bound
            )
        )
        #expect(max(decoded.width, decoded.height) <= 120)
    }

    // MARK: - The cache

    @Test("The cache evicts at its byte bound, and never the entry just made")
    func theCacheEvictsAtItsByteBound() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        // One byte: every insert overruns it, so the trim runs on every insert
        // and the protection of the newest entry is what is being watched.
        let renderer = StaticLayerRenderer(store: store, byteBound: 1)

        let first = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)
        let second = try await scratch.imageLayer(store: store, color: .green, transform: .fullPage)

        let a = try await composited(renderer, layers: [first])
        #expect(await renderer.cachedCompositeCount == 1, "the entry just made is never the one evicted")
        #expect(await renderer.cachedByteCount == a.byteCount)

        let b = try await composited(renderer, layers: [second])
        #expect(await renderer.cachedCompositeCount == 1, "the older composite is gone at the bound")
        #expect(await renderer.cachedByteCount == b.byteCount)
        #expect(await renderer.cachedByteCount > 0, "the bound is stated in bytes and counted in bytes")
    }

    @Test("Under its bound, the cache holds both composites and re-serves them")
    func theCacheServesRepeatedRequests() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        let first = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)
        let second = try await scratch.imageLayer(store: store, color: .green, transform: .fullPage)

        let a = try await composited(renderer, layers: [first])
        _ = try await composited(renderer, layers: [second])
        #expect(await renderer.cachedCompositeCount == 2)

        let again = try await composited(renderer, layers: [first])
        #expect(again.image === a.image, "a repeat request must be served from the cache, not re-decoded")
    }

    @Test("A different level of detail is a different composite, not a reused one")
    func levelOfDetailIsPartOfTheIdentity() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)
        let layer = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)

        let coarse = try await composited(
            renderer, request: StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        let fine = try await composited(
            renderer, request: StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 2)
        )
        #expect(fine.image.width == coarse.image.width * 2)
        #expect(await renderer.cachedCompositeCount == 2)
    }

    @Test("Composites whose pages left the live window are evicted")
    func retainDropsCompositesOutsideTheLiveWindow() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        let kept = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)
        let gone = try await scratch.imageLayer(store: store, color: .green, transform: .fullPage)
        _ = try await composited(renderer, layers: [kept])
        _ = try await composited(renderer, layers: [gone])
        #expect(await renderer.cachedCompositeCount == 2)

        await renderer.retain(layerIDs: [kept.layerID])
        #expect(await renderer.cachedCompositeCount == 1)
        #expect(await renderer.cachedByteCount > 0)

        // Nothing is retained because it might be wanted again.
        await renderer.retain(layerIDs: [])
        #expect(await renderer.cachedCompositeCount == 0)
        #expect(await renderer.cachedByteCount == 0)
    }

    // MARK: - In flight

    @Test("An in-flight composite is not served to a request for a moved layer")
    func inFlightDedupIsTransformAware() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)
        let gate = RenderGate()
        await renderer.setRenderGateForTesting { await gate.wait($0) }

        // The same layer — same ID, same asset — before and after a drag: the
        // left half of the page, then the right half. The cache key is the
        // layer ID list, so the two requests collide on the key and differ
        // only in the transform, which is the exact interleaving of a commit
        // landing while the pre-drag composite is still decoding.
        let before = try await scratch.imageLayer(
            store: store,
            color: .red,
            transform: PageSpaceTransform(a: 306, b: 0, c: 0, d: 792, tx: 0, ty: 0)
        )
        let after = LayerEnvelope(
            layerID: before.layerID,
            kind: .image,
            payload: before.payload,
            pageSpaceTransform: PageSpaceTransform(a: 306, b: 0, c: 0, d: 792, tx: 306, ty: 0)
        )
        let staleRequest = StaticLayerRequest(layers: [before], geometry: .canonical, pixelsPerPagePoint: 1)
        let freshRequest = StaticLayerRequest(layers: [after], geometry: .canonical, pixelsPerPagePoint: 1)

        let stale = Task { await renderer.composite(for: staleRequest) }
        // Hold the first render in flight until the second request has asked.
        while await gate.waiterCount == 0 { await Task.yield() }
        let fresh = Task { await renderer.composite(for: freshRequest) }
        try await Task.sleep(for: .milliseconds(50))

        // The newer render completes first and the stale one last, so a
        // `remember` that caches unconditionally would park the stale
        // transform under the key the newer request uses.
        await gate.release(freshRequest)
        try await Task.sleep(for: .milliseconds(50))
        await gate.release(staleRequest)

        guard case .composited(let freshComposite) = await fresh.value else {
            Issue.record("the second request did not composite")
            return
        }
        #expect(
            isRed(pixel(freshComposite.image, x: 450, y: 400)),
            "the second request must reflect the moved transform, not the in-flight stale one"
        )
        #expect(isWhite(pixel(freshComposite.image, x: 150, y: 400)))

        guard case .composited(let staleComposite) = await stale.value else {
            Issue.record("the first request did not composite")
            return
        }
        #expect(isRed(pixel(staleComposite.image, x: 150, y: 400)), "the first request still gets what it asked for")

        // And the stale result was not remembered over the newer one: a
        // repeat of the newer request is a cache hit on the newer composite.
        let again = try await composited(renderer, request: freshRequest)
        #expect(again.image === freshComposite.image, "the newer composite is the one remembered")
    }

    /// Holds render tasks at the renderer's test gate until released, keyed by
    /// the whole request, so a test can order completions deterministically.
    private actor RenderGate {
        private var released: [StaticLayerRequest] = []
        private var waiters: [(request: StaticLayerRequest, continuation: CheckedContinuation<Void, Never>)] = []

        var waiterCount: Int { waiters.count }

        func wait(_ request: StaticLayerRequest) async {
            if released.contains(request) { return }
            await withCheckedContinuation { continuation in
                waiters.append((request, continuation))
            }
        }

        func release(_ request: StaticLayerRequest) {
            released.append(request)
            for waiter in waiters where waiter.request == request {
                waiter.continuation.resume()
            }
            waiters.removeAll { $0.request == request }
        }
    }

    // MARK: - A refused layer is never a wrong picture

    @Test("An asset that will not decode refuses the whole composite")
    func anUndecodableAssetRefusesTheComposite() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)

        let good = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)
        // A file that exists, is named `.png`, and is not an image. The durable
        // half cannot catch this: it checks that the asset is *there*.
        let broken = try await scratch.imageLayer(
            store: store, image: Data("not a picture".utf8), transform: .fullPage
        )

        // The broken layer is second, so a partial composite would be the
        // plausible wrong answer: everything below it drew fine.
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: [good, broken], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .refused(let why) = render else {
            Issue.record("a stack with an undecodable layer rendered as \(render)")
            return
        }
        #expect(why.contains(broken.layerID.uuidString))
    }

    @Test("An asset format this build cannot read refuses the composite")
    func anUnsupportedFormatRefusesTheComposite() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)

        // The shape a future HEIC asset takes to this build.
        let layer = LayerEnvelope(
            layerID: UUID(),
            kind: .image,
            payload: try ImageLayerRef(assetID: UUID(), rawFormat: "heic").encodedPayload(),
            pageSpaceTransform: .fullPage
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .refused(let why) = render else {
            Issue.record("an unreadable format rendered as \(render)")
            return
        }
        #expect(why.contains("heic"))
    }

    @Test("An asset that is not on disk refuses the composite")
    func aMissingAssetRefusesTheComposite() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)

        let layer = LayerEnvelope(
            layerID: UUID(),
            kind: .image,
            payload: try ImageLayerRef(assetID: UUID(), format: .png).encodedPayload(),
            pageSpaceTransform: .fullPage
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .refused = render else {
            Issue.record("a missing asset rendered as \(render)")
            return
        }
    }

    // MARK: - Off the main thread

    @Test("The decode and the composite do not run on the main thread")
    @MainActor
    func theCompositeIsBuiltOffMain() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)
        let layer = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)

        // Asked for from the main actor, exactly as the canvas runtime asks.
        // `pthread_main_np` for the same reason the renderer uses it: Swift 6
        // makes `Thread.isMainThread` unavailable from an async context.
        #expect(pthread_main_np() != 0, "this test must ask from the main thread or it proves nothing")
        let composite = try await composited(renderer, layers: [layer])
        #expect(
            composite.builtOffMain,
            "the composite ran on the main thread; Contract.md — Performance forbids image work there"
        )
    }

    // MARK: - The sibling stack

    @Test("A page with static layers gets a layer stack beneath a transparent canvas")
    @MainActor
    func theBackdropIsASiblingLayerBeneathTheCanvas() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let renderer = StaticLayerRenderer(store: store)
        let layer = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)

        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical, staticRenderer: renderer)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([layer])
        root.layoutIfNeeded()

        let backdrop = try #require(controller.backdrop)

        // A layer, not a subview: nothing was added to the view hierarchy at
        // all, which is what keeps it out of the scroll view's touch
        // bookkeeping.
        #expect(root.subviews.count == 1, "the backdrop must not be a subview")
        #expect(root.subviews.first === controller.canvasView)

        // And it is genuinely beneath the canvas in the host's sublayer order.
        let sublayers = try #require(root.layer.sublayers)
        let clipIndex = try #require(sublayers.firstIndex { $0 === backdrop.clipLayerForTesting })
        let canvasIndex = try #require(sublayers.firstIndex { $0 === controller.canvasView.layer })
        #expect(clipIndex < canvasIndex, "the stack must render before the ink surface")

        // The ink surface is transparent so the stack shows through, and the
        // root carries the page white the canvas used to paint.
        #expect(controller.canvasView.isOpaque == false)
        #expect(root.backgroundColor == .white)

        // The stack is masked to the slot, or a zoomed page would draw across
        // its neighbours in the paging scroll view.
        #expect(backdrop.clipLayerForTesting.masksToBounds)
        #expect(backdrop.clipLayerForTesting.frame == root.bounds)

        // Page-sized bounds in page points, anchored at the page origin: the
        // mirror is one transform and nothing else.
        //
        // The `Double(...)` conversions are load-bearing, not decoration.
        // `#expect(someCGFloat == someDouble)` **fails inside `#expect` even
        // when the two have identical bit patterns** — the implicit
        // CGFloat/Double conversion does not survive the macro's expansion, and
        // the failure message prints both operands as `612.0`, which is as
        // confusing as a test failure gets. Convert explicitly at every mixed
        // comparison in this repository.
        #expect(Double(backdrop.pageLayerForTesting.bounds.width) == PageGeometry.canonical.width)
        #expect(Double(backdrop.pageLayerForTesting.bounds.height) == PageGeometry.canonical.height)
        #expect(backdrop.pageLayerForTesting.anchorPoint == .zero)
    }

    @Test("A page with no static layers installs no stack and keeps an opaque canvas")
    @MainActor
    func aBlankPagePaysNothing() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([])
        root.layoutIfNeeded()

        #expect(controller.backdrop == nil)
        #expect(
            controller.canvasView.isOpaque,
            "a page with nothing beneath its ink must not pay for a full-screen blend"
        )
        #expect(root.layer.sublayers?.count == 1)
    }

    @Test("The mirror registers the stack with the scroll view's own geometry")
    @MainActor
    func theMirrorRegistersWithTheScroll() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let layer = try await scratch.imageLayer(
            store: store, color: .red, transform: .fullPage
        )

        let controller = PageCanvasController(
            toolPicker: PKToolPicker(), projection: .canonical, staticRenderer: StaticLayerRenderer(store: store)
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([layer])
        root.layoutIfNeeded()

        let page = try #require(controller.backdrop).pageLayerForTesting
        let canvas = controller.canvasView

        // Page point p renders at p * zoom - contentOffset.
        for (offset, zoom) in [
            (CGPoint(x: 0, y: 0), CGFloat(1)),
            (CGPoint(x: 40, y: 260), CGFloat(2.5)),
            (CGPoint(x: -33, y: -12), CGFloat(0.75)),
        ] {
            canvas.zoomScale = zoom
            canvas.contentOffset = offset
            controller.scrollViewDidScroll(canvas)

            let expected = CATransform3DScale(
                CATransform3DMakeTranslation(-offset.x, -offset.y, 0), zoom, zoom, 1
            )
            #expect(
                CATransform3DEqualToTransform(page.transform, expected),
                "the mirror drifted at offset \(offset), zoom \(zoom)"
            )
        }
    }

    @Test("The stack shows the composite once it lands, and the placeholder until then")
    @MainActor
    func theStackShowsThePlaceholderThenTheComposite() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let layer = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)

        let controller = PageCanvasController(
            toolPicker: PKToolPicker(), projection: .canonical, staticRenderer: StaticLayerRenderer(store: store)
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([layer])
        root.layoutIfNeeded()

        let page = try #require(controller.backdrop).pageLayerForTesting

        // Synchronously after the request: a tint, never a blank page.
        #expect(page.contents == nil)
        #expect(page.backgroundColor != nil, "a page awaiting its composite shows a placeholder tint")

        try await waitUntil("the composite lands") { page.contents != nil }
        #expect(page.backgroundColor == nil, "a composited page is its texture, not a tint")
    }

    @Test("A stack that refuses shows a refusal, not a partial picture")
    @MainActor
    func aRefusedStackShowsARefusal() async throws {
        let scratch = try Scratch()
        let store = scratch.store
        let good = try await scratch.imageLayer(store: store, color: .red, transform: .fullPage)
        let broken = try await scratch.imageLayer(
            store: store, image: Data("not a picture".utf8), transform: .fullPage
        )

        let controller = PageCanvasController(
            toolPicker: PKToolPicker(), projection: .canonical, staticRenderer: StaticLayerRenderer(store: store)
        )
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        controller.setStaticLayers([good, broken])
        root.layoutIfNeeded()

        let page = try #require(controller.backdrop).pageLayerForTesting
        let loadingTint = page.backgroundColor

        try await waitUntil("the refusal lands") { page.backgroundColor !== loadingTint }
        #expect(page.contents == nil, "a refused stack must not show the layers it could read")
        #expect(page.backgroundColor != nil)
    }

    // MARK: - Through the session

    @Test("An imported image becomes visible under the ink of a live page")
    @MainActor
    func anImportedImageRendersUnderTheInk() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store, debounce: .milliseconds(10))
        await session.start()

        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let canvasPage = try #require(session.currentCanvas)
        #expect(canvasPage.backdrop == nil, "a blank page starts with nothing beneath its ink")

        let png = Scratch.solidPNG(width: 400, height: 300, color: .green)
        _ = try await session.importImage(png, format: .png, sourceWidth: 400, sourceHeight: 300)
        root.layoutIfNeeded()

        // The same canvas, told rather than rebuilt: an import must not touch
        // the page's ink.
        #expect(session.currentCanvas === canvasPage)
        let backdrop = try #require(canvasPage.backdrop, "the import installed no backdrop")
        let page = backdrop.pageLayerForTesting
        try await waitUntil("the imported image composites") { page.contents != nil }
    }

    @Test("A page carrying a refused layer offers no static layers to render")
    @MainActor
    func aRefusedPageRendersNothing() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let assetID = UUID()

        // A page whose image layer names an asset that is not on disk: the
        // durable half refuses the layer, and the page refuses input.
        let missing = LayerEnvelope(
            layerID: UUID(),
            kind: .image,
            payload: try ImageLayerRef(assetID: assetID, format: .png).encodedPayload(),
            pageSpaceTransform: .fullPage
        )
        let ink = LayerEnvelope(
            layerID: UUID(), kind: .ink, payload: Data(), pageSpaceTransform: .identity
        )
        try await scratch.store.writeAsset(Data([0x01]), assetID: assetID, format: .png)
        try await scratch.store.save(
            index: scratch.index(pageIDs: [pageID]), changedPages: [pageID: [missing, ink]]
        )
        try scratch.removeAsset(assetID)

        let session = EditorSession(store: scratch.store, debounce: .milliseconds(10))
        await session.start()
        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        // No canvas at all: a page that refuses input is a placeholder, so
        // there is no backdrop and no composite to be mistaken for correct.
        #expect(session.currentCanvas == nil)
        #expect(session.pages.liveCanvasCount == 0)
    }

    // MARK: - Helpers

    private func composited(
        _ renderer: StaticLayerRenderer,
        layers: [LayerEnvelope]
    ) async throws -> StaticComposite {
        try await composited(
            renderer, request: StaticLayerRequest(layers: layers, geometry: .canonical, pixelsPerPagePoint: 1)
        )
    }

    private func composited(
        _ renderer: StaticLayerRenderer,
        request: StaticLayerRequest
    ) async throws -> StaticComposite {
        let render = await renderer.composite(for: request)
        guard case .composited(let composite) = render else {
            throw CompositeFailure(render: "\(render)")
        }
        return composite
    }

    private struct CompositeFailure: Error, CustomStringConvertible {
        let render: String
        var description: String { "expected a composite, got \(render)" }
    }

    /// Polls until `condition` holds, or fails after a second.
    ///
    /// A poll rather than a sleep: the composite is a real off-main task and
    /// the point is that it lands, not that it lands within any particular
    /// interval — an interval assertion here would be a flake generator on a
    /// loaded CI runner.
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

    /// One pixel of a composite, as 8-bit RGB.
    ///
    /// The composite is drawn into a context of a known layout rather than read
    /// through `CGImage`'s own data provider, whose byte order and alpha
    /// arrangement are the renderer's business and not this test's.
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
        // Translate the wanted pixel to the origin of a 1x1 viewport. CGImage
        // row 0 is the top, and CoreGraphics draws from the bottom, so the y
        // axis is flipped once here.
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
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 0) && near(p.b, 255)
    }
    private func isYellow(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 0)
    }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 255)
    }

    // MARK: A scratch document

    /// A unique directory per test, with a store over it. A class, not a
    /// struct, because the assertions above capture it.
    private final class Scratch {
        let root: URL
        let store: DocumentStore

        var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-render-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("JustACanvas.tubernotes/pages"),
                withIntermediateDirectories: true
            )
            store = DocumentStore(directoryURL: root.appendingPathComponent("JustACanvas.tubernotes"))
        }

        func index(pageIDs: [UUID]) -> DocumentIndex {
            DocumentIndex(
                formatVersion: DocumentIndex.currentFormatVersion,
                documentID: UUID(),
                pages: pageIDs.map { PageRecord(id: $0, geometry: .canonical) },
                currentPageIndex: 0
            )
        }

        func removeAsset(_ assetID: UUID) throws {
            try FileManager.default.removeItem(
                at: documentURL.appendingPathComponent("assets/\(assetID.uuidString).png")
            )
        }

        /// Writes an asset and returns the layer envelope naming it.
        func imageLayer(
            store: DocumentStore,
            color: UIColor,
            transform: PageSpaceTransform
        ) async throws -> LayerEnvelope {
            try await imageLayer(
                store: store,
                image: Self.solidPNG(width: 64, height: 64, color: color),
                transform: transform
            )
        }

        func imageLayer(
            store: DocumentStore,
            image: Data,
            transform: PageSpaceTransform
        ) async throws -> LayerEnvelope {
            let assetID = UUID()
            try await store.writeAsset(image, assetID: assetID, format: .png)
            return try LayerEnvelope.image(
                layerID: UUID(),
                ref: ImageLayerRef(assetID: assetID, format: .png),
                pageSpaceTransform: transform
            )
        }

        /// PNG bytes for a solid rectangle. Built in memory through ImageIO —
        /// the same decoder the renderer uses, from the other end.
        static func solidPNG(width: Int, height: Int, color: UIColor) -> Data {
            png(width: width, height: height) { context in
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        /// PNG bytes whose top half is one colour and bottom half another, so
        /// orientation is observable rather than assumed.
        static func twoTonePNG(top: UIColor, bottom: UIColor) -> Data {
            png(width: 64, height: 64) { context in
                context.setFillColor(bottom.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
                context.setFillColor(top.cgColor)
                context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
            }
        }

        private static func png(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Data {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                preconditionFailure("could not build a \(width)x\(height) context")
            }
            draw(context)
            guard let image = context.makeImage() else {
                preconditionFailure("the context yielded no image")
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil
            ) else {
                preconditionFailure("no PNG destination")
            }
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination), "PNG encoding failed")
            return out as Data
        }
    }
}

private extension PageSpaceTransform {
    /// The whole page, the way `EditorSession.importImage` places a source with
    /// the page's own aspect ratio.
    static let fullPage = PageSpaceTransform(
        a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
    )
}

import CoreGraphics
import ImageIO
import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// Phase 3c, third deliverable: a settled turn warms neighbour pages' base
/// composites through the existing renderer cache, so a swipe lands on a
/// rendered worksheet rather than a placeholder tint.
///
/// The gate this rides on — turns commit once, at settle — is pinned by
/// `PagedCanvasControllerTests`; what is proven here is the warm itself: a
/// page at prefetch distance, with no canvas and no request from any
/// controller, has its composite in the cache after a settled turn, and the
/// canvas built when the page later turns live is served that identical
/// render. Plus the protection rule: byte-bound pressure from warming never
/// evicts a composite of the visible page.
@Suite("Prefetch decode at turns")
struct PrefetchWarmTests {

    @Test("A settled turn warms a prefetch-distance page's composite; its canvas later hits it")
    @MainActor
    func aSettledTurnWarmsTheNeighbour() async throws {
        let scratch = try TestScratch("warm")

        // Five pages; page 4 carries an image layer. From page 1, page 4 is at
        // prefetch distance 3 — inside the session's radius, outside the
        // paging runtime's live window, so no canvas exists to ask anything.
        // The two radii moved together on 2026-08-07 (window 1→2, prefetch
        // 2→3); this distance is chosen from that relationship, not from the
        // numbers, so it stays the right test if they move again.
        let pageIDs = (0..<5).map { _ in UUID() }
        let decorated = try await scratch.imageLayer(color: .green)
        var pages: [UUID: [LayerEnvelope]] = [:]
        for (i, id) in pageIDs.enumerated() {
            let ink = LayerEnvelope(
                layerID: UUID(), kind: .ink, payload: Data(), pageSpaceTransform: .identity
            )
            pages[id] = i == 4 ? [decorated, ink] : [ink]
        }
        try await scratch.store.save(index: scratch.index(pageIDs: pageIDs), changedPages: pages)

        let session = EditorSession(store: scratch.store, debounce: .milliseconds(10))
        await session.start()
        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let renderer = session.staticRendererForTesting
        #expect(await renderer.cachedCompositeCount == 0, "nothing composites before any turn or canvas needs it")

        // One settled turn to page 1.
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width, y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        root.layoutIfNeeded()

        #expect(session.pages.livePage(at: 4) == nil, "page 4 must have no canvas — the warm is the only requester")
        try await waitUntil("the neighbour's composite warms") {
            await renderer.cachedCompositeCount == 1
        }

        // The identity the cache holds, taken now, before any canvas exists.
        let detail = try #require(session.pages.compositeDetail(forPageAt: 4))
        let request = StaticLayerRequest(
            layers: [decorated],
            geometry: .canonical,
            pixelsPerPagePoint: detail
        )
        let warmed = await renderer.composite(for: request)
        guard case .composited(let warm) = warmed else {
            Issue.record("the warmed request missed: \(warmed) — the warm rendered something else")
            return
        }

        // Turn to page 2: page 4 enters the live window and builds a canvas,
        // which requests its composite as it lays out — and must be served
        // the warmed render, not a fresh one.
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2, y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        root.layoutIfNeeded()

        let neighbour = try #require(session.pages.livePage(at: 4), "page 4 is in the live window now")
        let backdrop = try #require(neighbour.backdrop)
        let pageLayer = backdrop.pageLayerForTesting
        try await waitUntilOnMain("the composite shows") { pageLayer.contents != nil }
        #expect(
            (pageLayer.contents as! CGImage) === warm.image,
            "the canvas must be served the warmed composite — identity, not a re-render"
        )
    }

    @Test("Warming never evicts the visible page's composite at the byte bound")
    func warmingCannotEvictTheVisiblePage() async throws {
        let scratch = try TestScratch("warm")
        // One byte: every insert overruns the bound, so without protection the
        // second composite would evict the first.
        let renderer = StaticLayerRenderer(store: scratch.store, byteBound: 1)

        let visible = try await scratch.imageLayer(color: .red)
        let neighbour = try await scratch.imageLayer(color: .green)
        let visibleRequest = StaticLayerRequest(
            layers: [visible], geometry: .canonical, pixelsPerPagePoint: 1
        )
        let neighbourRequest = StaticLayerRequest(
            layers: [neighbour], geometry: .canonical, pixelsPerPagePoint: 1
        )

        guard case .composited(let shown) = await renderer.composite(for: visibleRequest) else {
            Issue.record("the visible composite did not render")
            return
        }
        await renderer.retain(
            layerIDs: [visible.layerID, neighbour.layerID],
            protecting: [visible.layerID]
        )
        await renderer.warm(neighbourRequest)

        // Both live: the warm inserted (insert-protected) and the visible
        // page's composite survived (window-protected), over-bound by design.
        #expect(await renderer.cachedCompositeCount == 2)
        guard case .composited(let again) = await renderer.composite(for: visibleRequest) else {
            Issue.record("the visible composite vanished")
            return
        }
        #expect(again.image === shown.image, "the visible page's composite must never be traded for speculation")
    }

    @Test("A warm of a composite already cached is a no-op that does not touch recency")
    func aWarmHitLeavesRecencyAlone() async throws {
        let scratch = try TestScratch("warm")
        // A bound that fits two of these composites but not three, so LRU
        // order decides who dies on the third insert.
        let renderer = StaticLayerRenderer(store: scratch.store, byteBound: 3_700_000)
        let layer = try await scratch.imageLayer(color: .red)
        let a = StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 1.0)
        let b = StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 0.9)
        let c = StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 0.8)

        guard case .composited(let first) = await renderer.composite(for: a) else { return }
        _ = await renderer.composite(for: b)
        // A *use* of A would make B the eviction candidate; a *warm* of A must
        // not. B was used more recently than A, so the third insert evicts A.
        await renderer.warm(a)
        _ = await renderer.composite(for: c)

        guard case .composited(let aAgain) = await renderer.composite(for: a) else { return }
        #expect(
            aAgain.image !== first.image,
            "a warm hit must not count as a use; A stayed least-recent and was evicted"
        )
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        _ condition: @Sendable () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    @MainActor
    private func waitUntilOnMain(
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
}

private extension TestScratch {
    /// A full-page image layer — the only shape this suite's fixtures take.
    func imageLayer(color: UIColor) async throws -> LayerEnvelope {
        try await imageLayer(
            color: color,
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0,
                c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
            )
        )
    }
}

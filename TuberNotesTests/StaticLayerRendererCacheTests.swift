import CoreGraphics
import Foundation
import Testing
@testable import TuberModel
@testable import TuberRender
@testable import TuberStore
import UIKit

/// What the render cache keeps and what it drops — as questions about a
/// **page**, which is what they became.
///
/// ## The defect this suite exists for
///
/// Eviction used to ask whether an entry's layer IDs were disjoint with the
/// live set, and **the empty set is disjoint with every set**. An entry with
/// no layers was therefore dropped by every `retain`, including the one that
/// named the page it was on screen for; the byte-bound trim's protection had
/// the same hole, for the same reason. It never fired, because every cached
/// composite has at least one layer — a page with none short-circuits to
/// `.empty` before the cache is reached. That is a property of what this
/// renderer is asked for today and never a property of the design, and the
/// paper template ends it: a blank page acquires a composite made of ruling
/// and no layers at all.
///
/// So these tests pin the property rather than the symptom: **retention and
/// protection are decided by page identity, and a page's layer list has no
/// say in either.** Revert either condition to a set operation over layer IDs
/// and the tests below fail, because a page ID is not a layer ID.
///
/// The layer-less entry the defect was really about was unwritable until the
/// template was drawn — `composite` short-circuited to `.empty` before the
/// cache was reached, so no such entry could exist to be evicted.
/// `aTemplatedLayerLessPageIsRetainedByItsPage` is that case, and it is the
/// one this file was waiting for.
@Suite("The render cache, by page")
struct StaticLayerRendererCacheTests {

    @Test("A templated page with no layers is retained and dropped by its page, like any other")
    func aTemplatedLayerLessPageIsRetainedByItsPage() async throws {
        let scratch = try TestScratch("cache")
        let renderer = StaticLayerRenderer(store: scratch.store)

        // No layers at all, so the entry's layer-ID set is empty — and the
        // empty set is disjoint with every set, which is exactly what the old
        // eviction asked about.
        let onScreen = UUID()
        let request = StaticLayerRequest(
            pageID: onScreen,
            layers: [],
            geometry: .canonical,
            template: .lined,
            pixelsPerPagePoint: 1
        )
        guard case .composited(let made) = await renderer.composite(for: request) else {
            Issue.record("a templated page with no layers did not composite")
            return
        }

        await renderer.retain(pageIDs: [onScreen])
        #expect(
            await renderer.cachedCompositeCount == 1,
            "the page the user is looking at kept its paper through a retain that named it"
        )
        guard case .composited(let again) = await renderer.composite(for: request) else {
            Issue.record("the composite vanished")
            return
        }
        #expect(again.image === made.image, "it must be the composite already made, not a re-render")

        await renderer.retain(pageIDs: [UUID()])
        #expect(await renderer.cachedCompositeCount == 0, "and it goes when its page leaves the window")
        #expect(await renderer.cachedByteCount == 0)
    }

    @Test("A template change replaces the cached composite rather than adding one")
    func aTemplateChangeOverwritesItsEntry() async throws {
        let scratch = try TestScratch("cache")
        let renderer = StaticLayerRenderer(store: scratch.store)
        let page = UUID()

        func request(_ template: PageTemplate) -> StaticLayerRequest {
            StaticLayerRequest(
                pageID: page,
                layers: [],
                geometry: .canonical,
                template: template,
                pixelsPerPagePoint: 1
            )
        }

        guard case .composited(let ruled) = await renderer.composite(for: request(.lined)) else {
            Issue.record("the lined page did not composite")
            return
        }
        #expect(await renderer.cachedCompositeCount == 1)

        // The template is deliberately not in the cache key: with one value
        // per document there is never an adjacent page on other paper, so the
        // superseded entry can never be wanted again and is overwritten in
        // place rather than orphaned beside its replacement.
        guard case .composited(let squared) = await renderer.composite(for: request(.grid)) else {
            Issue.record("the grid page did not composite")
            return
        }
        #expect(squared.image !== ruled.image, "the new paper must actually be a new picture")
        #expect(
            await renderer.cachedCompositeCount == 1,
            "putting the template in the key would leave the superseded entry behind"
        )
    }
    @Test("A composite survives a retain naming its page, and goes when one does not")
    func retentionIsDecidedByPageIdentity() async throws {
        let scratch = try TestScratch("cache")
        let renderer = StaticLayerRenderer(store: scratch.store)

        let onScreen = UUID()
        let layer = try await scratch.imageLayer(color: .red, transform: .fullPage)
        let request = StaticLayerRequest(
            pageID: onScreen,
            layers: [layer],
            geometry: .canonical,
            template: .blank,
            pixelsPerPagePoint: 1
        )
        guard case .composited(let made) = await renderer.composite(for: request) else {
            Issue.record("the composite did not render")
            return
        }

        // The live set names the page and says nothing about its layers, which
        // is the whole point: a page with no layers can still be named.
        await renderer.retain(pageIDs: [onScreen])
        #expect(await renderer.cachedCompositeCount == 1)

        // Identity, not the counter: a re-render would also count 1.
        guard case .composited(let again) = await renderer.composite(for: request) else {
            Issue.record("the composite vanished")
            return
        }
        #expect(again.image === made.image, "the page was live, so its composite must be the one already made")

        // And a live set that does not name it drops it, because nothing is
        // retained on the chance it is wanted again.
        await renderer.retain(pageIDs: [UUID()])
        #expect(await renderer.cachedCompositeCount == 0)
        #expect(await renderer.cachedByteCount == 0)
    }

    @Test("The byte-bound trim protects the page on screen by identity")
    func theTrimProtectsTheVisiblePageByIdentity() async throws {
        let scratch = try TestScratch("cache")
        // One byte: every insert overruns the bound, so the trim runs on each
        // one and only the protection decides who survives it.
        let renderer = StaticLayerRenderer(store: scratch.store, byteBound: 1)

        let visiblePage = UUID()
        let neighbourPage = UUID()
        let onScreen = try await scratch.imageLayer(color: .red, transform: .fullPage)
        let nextDoor = try await scratch.imageLayer(color: .green, transform: .fullPage)
        let visibleRequest = StaticLayerRequest(
            pageID: visiblePage,
            layers: [onScreen],
            geometry: .canonical,
            template: .blank,
            pixelsPerPagePoint: 1
        )
        let neighbourRequest = StaticLayerRequest(
            pageID: neighbourPage,
            layers: [nextDoor],
            geometry: .canonical,
            template: .blank,
            pixelsPerPagePoint: 1
        )

        guard case .composited(let shown) = await renderer.composite(for: visibleRequest) else {
            Issue.record("the visible composite did not render")
            return
        }
        await renderer.retain(pageIDs: [visiblePage, neighbourPage], protecting: [visiblePage])

        // The neighbour's insert overruns the bound and the trim walks; the
        // page on screen is passed over by its own identity.
        _ = await renderer.composite(for: neighbourRequest)
        #expect(await renderer.cachedCompositeCount == 2, "both survive: one protected, one just inserted")

        guard case .composited(let again) = await renderer.composite(for: visibleRequest) else {
            Issue.record("the visible composite vanished")
            return
        }
        #expect(
            again.image === shown.image,
            "the composite on screen is never traded to make room for another page's"
        )
    }
}

private extension PageSpaceTransform {
    /// The whole page — the placement `EditorSession.importImage` gives a
    /// source with the page's own aspect ratio.
    static let fullPage = PageSpaceTransform(
        a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
    )
}

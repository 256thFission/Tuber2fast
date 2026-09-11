import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import TNFormat
@testable import TNModel
@testable import TNRender

/// A renderer over no assets: drawn paper and ink need none.
private struct NoAssets: AssetReading {
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data { throw .invalidWrite("no assets") }
}

@Suite("Renderer: thumbnails and the bounded caches")
struct RendererTests {
    private let letter = PageGeometry.letter
    private let landscape = PageGeometry(width: 792, height: 612)

    @Test("A thumbnail's long edge is exactly the constant, portrait and landscape")
    func longEdgeIsExact() async throws {
        let renderer = Renderer(assets: NoAssets())
        let long = Renderer.thumbnailLongEdgePixels
        let portrait = try #require(await renderer.thumbnail(ThumbnailKey(page: PageID(), version: 1), geometry: letter, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(portrait.height == long && portrait.width == 371)
        let wide = try #require(await renderer.thumbnail(ThumbnailKey(page: PageID(), version: 1), geometry: landscape, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(wide.width == long && wide.height == 371)
        #expect(Renderer.thumbnailPixels(for: letter) == (371, 480))
    }

    @Test("A stroke is dark at the stroke and the paper is white away from it")
    func inkLandsWhereDrawn() async throws {
        let renderer = Renderer(assets: NoAssets())
        let image = try #require(await renderer.thumbnail(
            ThumbnailKey(page: PageID(), version: 1), geometry: letter, paper: .drawn(.blank), layers: [], ink: Ink.drawing(strokes: 1)))
        // The fixture stroke runs from x 10 to 70 at y 10, in page points.
        let scale = Double(image.height) / letter.height
        #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128)
        #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) == 255)
    }

    @Test("A cached thumbnail hits on its key and misses on another version")
    func cacheHitsOnKey() async throws {
        let renderer = Renderer(assets: NoAssets())
        let page = PageID()
        let key = ThumbnailKey(page: page, version: 3)
        #expect(await renderer.cachedThumbnail(key) == nil)
        let rendered = try #require(await renderer.thumbnail(key, geometry: letter, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(await renderer.cachedThumbnail(key) === rendered)
        #expect(await renderer.cachedThumbnail(ThumbnailKey(page: page, version: 4)) == nil)
        await renderer.purge()
        #expect(await renderer.cachedThumbnail(key) == nil)
    }

    @Test("A cancelled render caches nothing")
    func cancelledRenderCachesNothing() async throws {
        let renderer = Renderer(assets: NoAssets())
        let key = ThumbnailKey(page: PageID(), version: 1)
        let geometry = letter
        let task = Task { await renderer.thumbnail(key, geometry: geometry, paper: .drawn(.blank), layers: [], ink: PKDrawing()) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await renderer.cachedThumbnail(key) == nil)
    }

    @Test("Eviction is oldest first, to the byte bound; a replaced key becomes newest")
    func boundedCacheEvictsOldest() {
        var cache = BoundedCache<String, Int>(bound: 10, cost: { $0 })
        cache.insert(4, for: "a")
        cache.insert(4, for: "b")
        cache.insert(4, for: "c")
        #expect(cache["a"] == nil && cache["b"] == 4 && cache["c"] == 4)
        #expect(cache.bytes == 8)
        cache.insert(2, for: "b")
        #expect(cache.bytes == 6)
        cache.insert(4, for: "d")
        #expect(cache["c"] == 4, "exactly at the bound is not over it")
        cache.insert(1, for: "e")
        #expect(cache["c"] == nil, "b was refreshed, so c is the oldest")
        #expect(cache["b"] == 2 && cache["d"] == 4 && cache["e"] == 1)
        #expect(cache.bytes == 7, "eviction stops once under the bound")
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0)
    }
}
